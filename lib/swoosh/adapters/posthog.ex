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

    * `capture_engagement` (boolean) - whether PostHog tracks opens and clicks.

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

  ## Using templates

  A template made in PostHog sets its own sender, subject and content, so the
  email carries only the recipient. The `from` that `Swoosh.Mailer` requires is
  not sent.

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
      cc, bcc, reply-to or attachments.
    * `:invalid_template_key` - a `template_key` PostHog can't take.

  Recipient display names are dropped, since PostHog takes bare addresses; the
  `from` display name is kept.

  ## Errors

  An API error returns `{:error, error}`, where `error` is a map with the
  `status`, the API's `code`, `detail` and `attr`, `retryable` and
  `retry_after` (seconds, or `nil`). A network error has `status: nil`, the
  code `"network_error"` and the client's `reason`. Retry only when `retryable`
  is true, and with the same `idempotency_key`: a 503 or a network error may
  still have sent the email. The adapter doesn't retry by itself.
  """

  use Swoosh.Adapter, required_config: [:api_key]

  alias Swoosh.Email

  @base_url "https://us.posthog.com"
  @api_endpoint "/api/projects/@current/messaging/send/email/"
  @integration "swoosh"
  @template_key ~r/\A[a-zA-Z0-9_-]{1,400}\z/
  @ignored_header ~r/\A(message-id|date|mime-version|content-.+|x-mailer)\z/i

  def deliver(%Email{} = email, config \\ []) do
    with :ok <- refuse_unsupported(email),
         {:ok, body} <- prepare_body(email, config) do
      post(email, body, config)
    end
  end

  defp refuse_unsupported(email) do
    case unsupported(email) do
      nil -> :ok
      reason -> unsupported_error(reason)
    end
  end

  defp unsupported(%Email{to: to}) when length(to) != 1, do: :multiple_to

  defp unsupported(email) do
    cond do
      Enum.any?(email.attachments, &inline_without_cid?/1) -> :inline_without_cid
      Enum.any?(Map.keys(email.headers), &(not ignored_header?(&1))) -> :unsupported_header
      has_option?(email, :tags) -> :tags
      has_option?(email, :metadata) -> :metadata
      has_option?(email, :scheduled_at) or has_option?(email, :send_at) -> :scheduled_send
      true -> nil
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
      email.cc != [] or email.bcc != [] or reply_to(email) != [] or email.attachments != []
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
    |> put_present("attachments", Enum.map(email.attachments, &attachment/1))
    |> put_present("distinct_id", email.provider_options[:distinct_id])
    |> put_present("capture_engagement", email.provider_options[:capture_engagement])
  end

  defp recipient(%Email{to: [{_name, address}]}), do: address

  defp sender(nil), do: nil
  defp sender({name, address}) when name in [nil, ""], do: address
  defp sender({name, address}), do: "#{name} <#{address}>"

  defp reply_to(email), do: List.wrap(email.reply_to)

  defp addresses(recipients), do: Enum.map(recipients, fn {_name, address} -> address end)

  defp attachment(attachment) do
    %{
      "filename" => attachment.filename,
      "content_type" => attachment.content_type,
      "content" => Swoosh.Attachment.get_content(attachment, :base64)
    }
    |> put_present("content_id", if(attachment.type == :inline, do: attachment.cid))
  end

  defp put_present(body, _key, value) when value in [nil, []], do: body
  defp put_present(body, key, value), do: Map.put(body, key, value)

  defp post(email, body, config) do
    url = [base_url(config), @api_endpoint]
    payload = Swoosh.json_library().encode!(body)

    case Swoosh.ApiClient.post(url, request_headers(email, config), payload, email) do
      {:ok, status, _headers, response} when status in 200..299 ->
        {:ok, %{id: response |> decode() |> Map.get("message_id")}}

      {:ok, status, headers, response} ->
        {:error, api_error(status, headers, response)}

      {:error, reason} ->
        {:error, network_error(reason)}
    end
  end

  defp base_url(config), do: String.trim_trailing(config[:base_url] || @base_url, "/")

  defp request_headers(email, config) do
    headers = [
      {"Authorization", "Bearer #{config[:api_key]}"},
      {"Content-Type", "application/json"},
      {"Accept", "application/json"},
      {"User-Agent", "swoosh/#{Swoosh.version()}"},
      {"X-PostHog-Integration", "#{@integration}/#{Swoosh.version()}"}
    ]

    case email.provider_options[:idempotency_key] do
      nil -> headers
      key -> [{"Idempotency-Key", key} | headers]
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

  defp network_error(reason) do
    %{
      status: nil,
      code: "network_error",
      detail: "The request to PostHog failed, so the email may or may not have been sent.",
      attr: nil,
      retryable: true,
      retry_after: nil,
      reason: reason
    }
  end

  defp retryable?(409, "idempotency_key_in_flight"), do: true
  defp retryable?(429, "quota_limited"), do: false
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
      _ -> %{}
    end
  end
end
