defmodule Swoosh.Adapters.PostHog do
  @moduledoc ~S"""
  An adapter that sends email using PostHog's transactional email API.

  For reference: [PostHog Workflows docs](https://posthog.com/docs/workflows)

  **This adapter requires an API Client.** Swoosh comes with Hackney, Finch and Req out of the box.
  See the [installation section](https://hexdocs.pm/swoosh/Swoosh.html#module-installation)
  for details.

  ## Example

      # config/config.exs
      config :sample, Sample.Mailer,
        adapter: Swoosh.Adapters.PostHog,
        api_key: "phs_123456789"

      # lib/sample/mailer.ex
      defmodule Sample.Mailer do
        use Swoosh.Mailer, otp_app: :sample
      end

  ## Configuration options

    * `api_key` (required) - a project secret API key (`phs_...`) with the
      `transactional_email:write` scope. The project capture key (`phc_...`)
      can't send email.

    * `base_url` - the PostHog app host. Defaults to `https://us.posthog.com`.
      Use `https://eu.posthog.com` for EU Cloud, or your own host when self-hosted.

    * `default_template_key` - groups sends in PostHog's reporting when an email
      sets no `template_key`. Defaults to `swoosh`.

  ## Provider options

    * `distinct_id` (string) - the PostHog person the send belongs to.
      Without it, PostHog uses the recipient's address.

    * `template_key` (string) - groups sends in PostHog's reporting. Letters,
      digits, `-` and `_`, at most 400.

    * `idempotency_key` (string) - sent as the `Idempotency-Key` header. Set it
      from a stable id when a job queue such as Oban retries the send, so a retry
      never sends twice.

    * `tracking` (boolean or map) - what PostHog tracks. `true` tracks opens,
      clicks and engagement events, `false` tracks none of them, and a map such
      as `%{opens: true, clicks: false, engagement: true}` sets each one. Left
      out, PostHog counts opens and captures engagement events, and tracks
      clicks only when the email isn't sensitive.

    * `sensitive` (boolean) - `true` for an email with login links, reset
      tokens or codes: PostHog leaves its links unchanged unless `tracking`
      turns clicks on, and keeps its subject off engagement events and its
      content out of logs. Left out, the email is sensitive unless a template
      made in PostHog with the same `template_key` says otherwise.

    * `template` (string) - the id of an email template made in PostHog.

    * `template_data` (map) - the data for that template.

      import Swoosh.Email

      new()
      |> from({"Shop", "shop@example.com"})
      |> to("ana@example.com")
      |> subject("Your order shipped")
      |> html_body("<p>On its way.</p>")
      |> put_provider_option(:distinct_id, "user_42")
      |> put_provider_option(:template_key, "order-shipped")
      |> put_provider_option(:idempotency_key, "order-981-shipped")
      |> put_provider_option(:tracking, %{clicks: false})

  ## Attachments

  PostHog takes files by their SHA-256. Before each send with attachments, the
  adapter asks PostHog which files it lacks, uploads those to the URL PostHog
  gives (an Amazon S3 host, not the PostHog host), and then sends the email.
  A file PostHog still has from an earlier send isn't uploaded again. If your
  network limits outgoing traffic, allow HTTPS to `*.s3.us-east-1.amazonaws.com`
  for US Cloud or `*.s3.eu-central-1.amazonaws.com` for EU Cloud.

  The upload needs an API client that implements `c:Swoosh.ApiClient.request/5`,
  as the clients that come with Swoosh do.

  ## Using templates

  A template made in PostHog sets its own sender, subject, content, tracking
  and sensitivity, so the email carries only the recipient, `distinct_id` and
  `idempotency_key`. The `from` that `Swoosh.Mailer` requires, and the
  `template_key` option, are not sent.

      new()
      |> from("shop@example.com")
      |> to("ana@example.com")
      |> put_provider_option(:template, "0190f0c2-7d1e-7a3b-9c2e-5f1a2b3c4d5e")
      |> put_provider_option(:template_data, %{order: "981"})

  ## What PostHog can't send

  The adapter refuses an email PostHog can't carry before any request goes out,
  instead of dropping part of it. It returns `{:error, {:unsupported, reason}}`:

    * `:multiple_to` - no `to`, or more than one. Send one email per recipient.
    * `:inline_without_cid` - an inline attachment without a `cid`.
    * `:unsupported_header` - a custom header. `Message-ID`, `Date`,
      `MIME-Version`, `Content-*` and `X-Mailer` are ignored.
    * `:tags`, `:metadata` - the `tags` or `metadata` provider options.
    * `:scheduled_send` - the `scheduled_at` or `send_at` provider options.
    * `:template_with_content` - a `template` together with a subject, body,
      cc, bcc, reply-to, attachments, `tracking` or `sensitive`.
    * `:invalid_template_key` - a `template_key` PostHog can't take.

  Recipient display names are dropped, since PostHog takes bare addresses; the
  `from` display name is kept.

  ## Errors

  An API error returns `{:error, error}`, where `error` is a map with the
  `status`, the API's `code`, `detail` and `attr`, `retryable` and
  `retry_after` (seconds, or `nil`). A network error has `status: nil`, the
  code `"network_error"` and the client's `reason`. A failed file upload has
  the code `"upload_failed"`, the storage host's `status` and its response as
  `detail`; the email isn't sent. Retry only when `retryable` is true, and with
  the same `idempotency_key`: a 503 or a network error may still have sent the
  email. The adapter doesn't retry by itself.
  """

  use Swoosh.Adapter, required_config: [:api_key]

  alias Swoosh.Email

  @base_url "https://us.posthog.com"
  @send_endpoint "/api/projects/@current/messaging/send/email/"
  @uploads_endpoint "/api/projects/@current/messaging/attachments/uploads/"
  @integration "swoosh"
  @template_key ~r/\A[a-zA-Z0-9_-]{1,400}\z/
  @mailbox_specials ~r/[()<>\[\]:;@\\,."]/
  @ignored_header ~r/\A(message-id|date|mime-version|content-.+|x-mailer)\z/i

  def deliver(%Email{} = email, config \\ []) do
    with :ok <- refuse_unsupported(email),
         {:ok, body} <- prepare_body(email, config),
         {:ok, body} <- attach_files(body, email, config),
         {:ok, fields} <- post(@send_endpoint, body, send_headers(email), email, config) do
      {:ok, %{id: fields["message_id"]}}
    end
  end

  defp refuse_unsupported(%Email{to: to}) when length(to) != 1,
    do: unsupported_error(:multiple_to)

  defp refuse_unsupported(email) do
    cond do
      Enum.any?(email.attachments, &inline_without_cid?/1) ->
        unsupported_error(:inline_without_cid)

      Enum.any?(Map.keys(email.headers), &(not ignored_header?(&1))) ->
        unsupported_error(:unsupported_header)

      has_option?(email, :tags) ->
        unsupported_error(:tags)

      has_option?(email, :metadata) ->
        unsupported_error(:metadata)

      has_option?(email, :scheduled_at) or has_option?(email, :send_at) ->
        unsupported_error(:scheduled_send)

      true ->
        :ok
    end
  end

  defp inline_without_cid?(attachment), do: attachment.type == :inline and attachment.cid == nil

  defp ignored_header?(name), do: Regex.match?(@ignored_header, name)

  defp has_option?(email, key), do: Map.has_key?(email.provider_options, key)

  defp unsupported_error(reason), do: {:error, {:unsupported, reason}}

  defp prepare_body(%Email{provider_options: %{template: template_id}} = email, _config) do
    if has_content?(email) do
      unsupported_error(:template_with_content)
    else
      {:ok, template_body(email, template_id)}
    end
  end

  defp prepare_body(email, config) do
    with {:ok, template_key} <- template_key(email, config) do
      {:ok, rendered_body(email, template_key)}
    end
  end

  defp has_content?(email) do
    email.subject != "" or email.html_body != nil or email.text_body != nil or
      email.cc != [] or email.bcc != [] or reply_to(email) != [] or email.attachments != [] or
      has_option?(email, :tracking) or has_option?(email, :sensitive)
  end

  defp template_body(email, template_id) do
    %{"to" => recipient(email), "template_id" => template_id}
    |> put_present("message_data", email.provider_options[:template_data])
    |> put_present("distinct_id", email.provider_options[:distinct_id])
  end

  defp template_key(email, config) do
    case email.provider_options[:template_key] do
      nil ->
        {:ok, config[:default_template_key] || @integration}

      key ->
        if valid_template_key?(key),
          do: {:ok, key},
          else: unsupported_error(:invalid_template_key)
    end
  end

  defp valid_template_key?(key), do: is_binary(key) and Regex.match?(@template_key, key)

  defp rendered_body(email, template_key) do
    %{"to" => recipient(email), "template_key" => template_key}
    |> put_present("from", sender(email.from))
    |> put_present("subject", if(email.subject != "", do: email.subject))
    |> put_present("html", email.html_body)
    |> put_present("text", email.text_body)
    |> put_present("cc", addresses(email.cc))
    |> put_present("bcc", addresses(email.bcc))
    |> put_present("reply_to", addresses(reply_to(email)))
    |> put_present("distinct_id", email.provider_options[:distinct_id])
    |> put_present("tracking", email.provider_options[:tracking])
    |> put_present("sensitive", email.provider_options[:sensitive])
  end

  defp recipient(%Email{to: [{_name, address}]}), do: address

  defp sender(nil), do: nil
  defp sender({name, address}) when name in [nil, ""], do: address
  defp sender({name, address}), do: "#{display_name(name)} <#{address}>"

  defp display_name(name) do
    if Regex.match?(@mailbox_specials, name), do: quoted(name), else: name
  end

  defp quoted(name), do: "\"" <> String.replace(name, ~r/["\\]/, "\\\\\\0") <> "\""

  defp reply_to(email), do: List.wrap(email.reply_to)

  defp addresses(recipients), do: Enum.map(recipients, fn {_name, address} -> address end)

  defp put_present(body, _key, value) when value in [nil, []], do: body
  defp put_present(body, key, value), do: Map.put(body, key, value)

  defp attach_files(body, %Email{attachments: []}, _config), do: {:ok, body}

  defp attach_files(body, email, config) do
    files = Enum.map(email.attachments, &file/1)

    with :ok <- upload_missing(Enum.uniq_by(files, & &1.sha256), email, config) do
      {:ok, Map.put(body, "attachments", Enum.map(files, &attachment/1))}
    end
  end

  defp file(attachment) do
    content = Swoosh.Attachment.get_content(attachment)
    sha256 = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
    %{attachment: attachment, content: content, sha256: sha256}
  end

  defp attachment(%{attachment: attachment, sha256: sha256}) do
    %{"sha256" => sha256, "filename" => attachment.filename}
    |> put_present("content_type", attachment.content_type)
    |> put_present("content_id", if(attachment.type == :inline, do: attachment.cid))
  end

  defp upload_missing(files, email, config) do
    request = %{
      "files" => Enum.map(files, &%{"sha256" => &1.sha256, "size" => byte_size(&1.content)})
    }

    contents = Map.new(files, &{&1.sha256, &1.content})

    case post(@uploads_endpoint, request, api_headers(), email, config) do
      {:ok, %{"files" => answers}} when is_list(answers) ->
        Enum.reduce_while(answers, :ok, fn answer, :ok ->
          case upload(answer, contents[answer["sha256"]], email) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      {:ok, _fields} ->
        {:error, upload_error(nil, "PostHog's upload route answered without files.", false)}

      error ->
        error
    end
  end

  defp upload(%{"status" => "upload", "method" => method, "url" => url} = answer, content, email)
       when is_binary(content) do
    headers = for {name, value} <- answer["headers"] || %{}, do: {String.downcase(name), value}

    with {:ok, method} <- upload_method(method) do
      case Swoosh.ApiClient.request(method, url, headers, content, email) do
        {:ok, status, _headers, _response} when status in 200..299 ->
          :ok

        {:ok, status, _headers, response} ->
          {:error, upload_error(status, response, status == 403 or status >= 500)}

        {:error, reason} ->
          {:error, network_error(reason, "The file upload failed, so the email wasn't sent.")}
      end
    end
  end

  defp upload(%{"status" => "present"}, _content, _email), do: :ok

  defp upload(answer, _content, _email) do
    {:error, upload_error(nil, "PostHog's upload route answered #{inspect(answer)}.", false)}
  end

  defp upload_method("PUT"), do: {:ok, :put}
  defp upload_method("POST"), do: {:ok, :post}

  defp upload_method(method) do
    {:error, upload_error(nil, "PostHog asked for an upload with #{inspect(method)}.", false)}
  end

  defp upload_error(status, detail, retryable) do
    %{
      status: status,
      code: "upload_failed",
      detail: detail,
      attr: nil,
      retryable: retryable,
      retry_after: nil
    }
  end

  defp post(endpoint, body, headers, email, config) do
    url = [base_url(config), endpoint]
    payload = Swoosh.json_library().encode!(body)
    headers = [{"Authorization", "Bearer #{config[:api_key]}"} | headers]

    case Swoosh.ApiClient.post(url, headers, payload, email) do
      {:ok, status, _headers, response} when status in 200..299 ->
        {:ok, decode(response)}

      {:ok, status, headers, response} ->
        {:error, api_error(status, headers, response)}

      {:error, reason} ->
        {:error,
         network_error(
           reason,
           "The request to PostHog failed, so the email may or may not have been sent."
         )}
    end
  end

  defp base_url(config), do: String.trim_trailing(config[:base_url] || @base_url, "/")

  defp api_headers do
    [
      {"Content-Type", "application/json"},
      {"Accept", "application/json"},
      {"User-Agent", "swoosh/#{Swoosh.version()}"},
      {"X-PostHog-Integration", "#{@integration}/#{Swoosh.version()}"}
    ]
  end

  defp send_headers(email) do
    case email.provider_options[:idempotency_key] do
      nil -> api_headers()
      key -> [{"Idempotency-Key", key} | api_headers()]
    end
  end

  defp api_error(status, headers, response) do
    fields = decode(response)

    %{
      status: status,
      code: fields["code"],
      detail: fields["detail"],
      attr: fields["attr"],
      retryable: retryable?(status, fields["code"]),
      retry_after: retry_after(headers)
    }
  end

  defp network_error(reason, detail) do
    %{
      status: nil,
      code: "network_error",
      detail: detail,
      attr: nil,
      retryable: true,
      retry_after: nil,
      reason: reason
    }
  end

  defp retryable?(409, "idempotency_key_in_flight"), do: true
  defp retryable?(429, "quota_limited"), do: false
  defp retryable?(429, "upload_quota_exceeded"), do: false
  defp retryable?(429, _code), do: true
  defp retryable?(503, _code), do: true
  defp retryable?(_status, _code), do: false

  defp retry_after(headers) do
    with {_name, value} <-
           Enum.find(headers, fn {name, _} -> String.downcase(name) == "retry-after" end),
         {seconds, ""} <- Integer.parse(value) do
      seconds
    else
      _ -> nil
    end
  end

  defp decode(response) do
    case Swoosh.json_library().decode(response) do
      {:ok, %{} = fields} -> fields
      _ -> %{"detail" => response}
    end
  end
end
