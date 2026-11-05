defmodule Swoosh.Adapters.PostHogTest do
  use Swoosh.AdapterCase, async: true

  import Swoosh.Email
  alias Swoosh.Adapters.PostHog

  defmodule Mailer do
    use Swoosh.Mailer, otp_app: :swoosh, adapter: Swoosh.Adapters.PostHog
  end

  @send_path "/api/projects/@current/messaging/send/email/"
  @message_id "0190f0c2-1111-7a3b-9c2e-5f1a2b3c4d5e"
  @template_id "0190f0c2-7d1e-7a3b-9c2e-5f1a2b3c4d5e"

  setup do
    bypass = Bypass.open()
    config = [api_key: "phs_test", base_url: "http://localhost:#{bypass.port}"]

    shipped =
      new()
      |> from({"Shop", "shop@example.com"})
      |> to({"Ana", "ana@example.com"})
      |> subject("Your order shipped")
      |> html_body("<p>On its way.</p>")
      |> text_body("On its way.")

    {:ok, bypass: bypass, config: config, shipped: shipped}
  end

  defp expect_send(bypass, assert_request) do
    Bypass.expect_once(bypass, "POST", @send_path, fn conn ->
      conn = parse(conn)
      assert_request.(conn)
      Plug.Conn.resp(conn, 202, ~s({"message_id": "#{@message_id}", "replayed": false}))
    end)
  end

  defp expect_body(bypass, body) do
    expect_send(bypass, fn conn ->
      assert get_header(conn, "x-posthog-integration") =~ ~r|\Aswoosh/[0-9A-Za-z.+-]{1,40}\z|
      assert get_header(conn, "idempotency-key") == nil
      assert conn.body_params == body
    end)
  end

  defp shipped_body(extra \\ %{}) do
    Map.merge(
      %{
        "to" => "ana@example.com",
        "from" => "Shop <shop@example.com>",
        "subject" => "Your order shipped",
        "html" => "<p>On its way.</p>",
        "text" => "On its way.",
        "template_key" => "swoosh"
      },
      extra
    )
  end

  defp respond_with(bypass, status, body, headers \\ []) do
    Bypass.expect_once(bypass, "POST", @send_path, fn conn ->
      headers
      |> Enum.reduce(conn, fn {name, value}, conn ->
        Plug.Conn.put_resp_header(conn, name, value)
      end)
      |> Plug.Conn.resp(status, body)
    end)
  end

  defp api_error(code, detail, attr \\ nil) do
    Jason.encode!(%{type: "validation_error", code: code, detail: detail, attr: attr})
  end

  defp get_header(conn, key) do
    case Enum.find(conn.req_headers, fn {k, _} -> k == key end) do
      {_, value} -> value
      nil -> nil
    end
  end

  describe "rendered form" do
    test "case 01: sends a minimal rendered email and returns its message id", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      expect_send(bypass, fn conn ->
        assert get_header(conn, "authorization") == "Bearer phs_test"
        assert get_header(conn, "content-type") == "application/json"
        assert get_header(conn, "x-posthog-integration") == "swoosh/#{Swoosh.version()}"
        assert get_header(conn, "idempotency-key") == nil
        assert conn.body_params == shipped_body()
      end)

      assert PostHog.deliver(email, config) == {:ok, %{id: @message_id}}
    end

    test "case 02: drops recipient display names and keeps the from name", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      email = email |> cc({"Bo", "bo@example.com"}) |> reply_to({"Help", "help@example.com"})

      expect_body(
        bypass,
        shipped_body(%{"cc" => ["bo@example.com"], "reply_to" => ["help@example.com"]})
      )

      assert {:ok, _} = PostHog.deliver(email, config)
    end

    test "case 03: sends cc, bcc and several reply-to addresses", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      email =
        email
        |> cc("bo@example.com")
        |> bcc("audit@example.com")
        |> reply_to(["a@example.com", "b@example.com"])

      expect_body(
        bypass,
        shipped_body(%{
          "cc" => ["bo@example.com"],
          "bcc" => ["audit@example.com"],
          "reply_to" => ["a@example.com", "b@example.com"]
        })
      )

      assert {:ok, _} = PostHog.deliver(email, config)
    end

    for {name, sent} <- [
          {"Acme, Inc", ~s("Acme, Inc" <shop@example.com>)},
          {~s(The "Best" Shop), ~s("The \\"Best\\" Shop" <shop@example.com>)}
        ] do
      test "quotes the from name #{name}", %{bypass: bypass, config: config, shipped: email} do
        expect_body(bypass, shipped_body(%{"from" => unquote(sent)}))

        assert {:ok, _} =
                 PostHog.deliver(from(email, {unquote(name), "shop@example.com"}), config)
      end
    end

    test "leaves out an attachment's unset content type", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      email = attachment(email, Swoosh.Attachment.new({:data, "x"}, filename: "notes"))

      expect_body(
        bypass,
        shipped_body(%{"attachments" => [%{"filename" => "notes", "content" => "eA=="}]})
      )

      assert {:ok, _} = PostHog.deliver(email, config)
    end

    test "case 04: sends attachments and inline parts with their content id", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      invoice =
        Swoosh.Attachment.new({:data, Base.decode64!("JVBERi0xLjQK")},
          filename: "invoice.pdf",
          content_type: "application/pdf"
        )

      logo =
        Swoosh.Attachment.new({:data, Base.decode64!("iVBORw0KGgo=")},
          filename: "logo.png",
          content_type: "image/png",
          type: :inline,
          cid: "logo"
        )

      email = %{html_body(email, ~s(<img src="cid:logo">)) | attachments: [invoice, logo]}

      expect_body(
        bypass,
        shipped_body(%{
          "html" => ~s(<img src="cid:logo">),
          "attachments" => [
            %{
              "filename" => "invoice.pdf",
              "content_type" => "application/pdf",
              "content" => "JVBERi0xLjQK"
            },
            %{
              "filename" => "logo.png",
              "content_type" => "image/png",
              "content" => "iVBORw0KGgo=",
              "content_id" => "logo"
            }
          ]
        })
      )

      assert {:ok, _} = PostHog.deliver(email, config)
    end

    test "case 05: sends the PostHog provider options", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      email =
        email
        |> put_provider_option(:distinct_id, "user_42")
        |> put_provider_option(:template_key, "order-shipped")
        |> put_provider_option(:idempotency_key, "order-981-shipped")
        |> put_provider_option(:capture_engagement, false)

      expect_send(bypass, fn conn ->
        assert get_header(conn, "idempotency-key") == "order-981-shipped"

        assert conn.body_params ==
                 shipped_body(%{
                   "template_key" => "order-shipped",
                   "distinct_id" => "user_42",
                   "capture_engagement" => false
                 })
      end)

      assert {:ok, _} = PostHog.deliver(email, config)
    end

    test "case 07: falls back to the configured default template key", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      expect_body(bypass, shipped_body(%{"template_key" => "transactional"}))

      assert {:ok, _} =
               PostHog.deliver(email, Keyword.put(config, :default_template_key, "transactional"))
    end

    test "case 11: ignores the headers a mailer always adds", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      email =
        email
        |> header("Message-ID", "<x@example.com>")
        |> header("Date", "Thu, 05 Nov 2026 10:00:00 +0000")
        |> header("MIME-Version", "1.0")
        |> header("Content-Language", "en")
        |> header("X-Mailer", "Swoosh")

      expect_body(bypass, shipped_body())

      assert {:ok, _} = PostHog.deliver(email, config)
    end

    test "accepts a base_url with a trailing slash", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      expect_body(bypass, shipped_body())

      assert {:ok, _} = PostHog.deliver(email, Keyword.update!(config, :base_url, &(&1 <> "/")))
    end
  end

  describe "template form" do
    test "case 15: sends a PostHog template with its data", %{bypass: bypass, config: config} do
      email =
        new()
        |> to({"Ana", "ana@example.com"})
        |> put_provider_option(:template, @template_id)
        |> put_provider_option(:template_data, %{order: "981"})
        |> put_provider_option(:distinct_id, "user_42")

      expect_body(bypass, %{
        "to" => "ana@example.com",
        "template_id" => @template_id,
        "message_data" => %{"order" => "981"},
        "distinct_id" => "user_42"
      })

      assert PostHog.deliver(email, config) == {:ok, %{id: @message_id}}
    end

    test "leaves out the from that Swoosh.Mailer requires, since the template sets its sender",
         %{bypass: bypass, config: config} do
      email =
        new()
        |> from({"Shop", "shop@example.com"})
        |> to("ana@example.com")
        |> put_provider_option(:template, @template_id)

      expect_body(bypass, %{"to" => "ana@example.com", "template_id" => @template_id})

      assert {:ok, _} = PostHog.deliver(email, config)
    end

    test "case 17: refuses a template with content", %{config: config, shipped: email} do
      email = put_provider_option(email, :template, @template_id)

      assert PostHog.deliver(email, config) == {:error, {:unsupported, :template_with_content}}
    end

    for field <- [:cc, :bcc, :reply_to, :attachment] do
      test "refuses a template with #{field}", %{config: config} do
        email =
          new()
          |> to("ana@example.com")
          |> put_provider_option(:template, @template_id)
          |> with_content(unquote(field))

        assert PostHog.deliver(email, config) == {:error, {:unsupported, :template_with_content}}
      end
    end
  end

  defp with_content(email, :cc), do: cc(email, "bo@example.com")
  defp with_content(email, :bcc), do: bcc(email, "audit@example.com")
  defp with_content(email, :reply_to), do: reply_to(email, "help@example.com")

  defp with_content(email, :attachment),
    do: attachment(email, Swoosh.Attachment.new({:data, "x"}, filename: "a.txt"))

  describe "refusals" do
    test "case 08: refuses an explicit template key PostHog can't take", %{
      config: config,
      shipped: email
    } do
      email = put_provider_option(email, :template_key, "order shipped!")

      assert PostHog.deliver(email, config) == {:error, {:unsupported, :invalid_template_key}}
    end

    test "case 09: refuses more than one to", %{config: config, shipped: email} do
      email = to(email, "bo@example.com")

      assert PostHog.deliver(email, config) == {:error, {:unsupported, :multiple_to}}
    end

    test "refuses an email with no to", %{config: config} do
      email = new() |> from("shop@example.com") |> subject("Hi") |> text_body("Hi")

      assert PostHog.deliver(email, config) == {:error, {:unsupported, :multiple_to}}
    end

    test "case 10: refuses an inline attachment without a content id", %{
      config: config,
      shipped: email
    } do
      email =
        attachment(
          email,
          Swoosh.Attachment.new({:data, "png"},
            filename: "logo.png",
            content_type: "image/png",
            type: :inline
          )
        )

      assert PostHog.deliver(email, config) == {:error, {:unsupported, :inline_without_cid}}
    end

    test "case 11: refuses a custom header next to an ignored one", %{
      config: config,
      shipped: email
    } do
      email = email |> header("Message-ID", "<x@example.com>") |> header("X-Campaign", "spring")

      assert PostHog.deliver(email, config) == {:error, {:unsupported, :unsupported_header}}
    end

    test "refuses PostHog option headers, which ride in provider options here", %{
      config: config,
      shipped: email
    } do
      email = header(email, "X-PostHog-Distinct-Id", "user_42")

      assert PostHog.deliver(email, config) == {:error, {:unsupported, :unsupported_header}}
    end

    test "case 12: refuses tags", %{config: config, shipped: email} do
      email = put_provider_option(email, :tags, ["receipts"])

      assert PostHog.deliver(email, config) == {:error, {:unsupported, :tags}}
    end

    test "case 12: refuses metadata", %{config: config, shipped: email} do
      email = put_provider_option(email, :metadata, %{"order" => "981"})

      assert PostHog.deliver(email, config) == {:error, {:unsupported, :metadata}}
    end

    for option <- [:scheduled_at, :send_at] do
      test "refuses a scheduled send through #{option}", %{config: config, shipped: email} do
        email = put_provider_option(email, unquote(option), "2026-11-06T10:00:00Z")

        assert PostHog.deliver(email, config) == {:error, {:unsupported, :scheduled_send}}
      end
    end
  end

  describe "errors" do
    test "400 is not retryable and names the field", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      respond_with(bypass, 400, api_error("invalid_input", "Enter a valid email address.", "to"))

      assert PostHog.deliver(email, config) ==
               {:error,
                %{
                  status: 400,
                  code: "invalid_input",
                  detail: "Enter a valid email address.",
                  attr: "to",
                  retryable: false,
                  retry_after: nil
                }}
    end

    for {status, code} <- [
          {401, "authentication_failed"},
          {403, "permission_denied"},
          {404, "not_found"},
          {422, "recipient_suppressed"},
          {429, "quota_limited"},
          {500, "error"}
        ] do
      test "#{status} #{code} is not retryable", %{bypass: bypass, config: config, shipped: email} do
        respond_with(bypass, unquote(status), api_error(unquote(code), "No."))

        assert {:error, %{status: unquote(status), code: unquote(code), retryable: false}} =
                 PostHog.deliver(email, config)
      end
    end

    test "409 idempotency_key_in_flight is retryable with the same key", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      respond_with(bypass, 409, api_error("idempotency_key_in_flight", "Still sending."))

      assert {:error, %{status: 409, code: "idempotency_key_in_flight", retryable: true}} =
               PostHog.deliver(email, config)
    end

    test "429 throttled is retryable after Retry-After", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      respond_with(bypass, 429, api_error("throttled", "Slow down."), [{"retry-after", "17"}])

      assert {:error, %{status: 429, code: "throttled", retryable: true, retry_after: 17}} =
               PostHog.deliver(email, config)
    end

    test "503 is retryable, because the send may still go out", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      respond_with(bypass, 503, "Service Unavailable")

      assert {:error, %{status: 503, code: nil, detail: "Service Unavailable", retryable: true}} =
               PostHog.deliver(email, config)
    end

    test "a network error is retryable", %{bypass: bypass, config: config, shipped: email} do
      Bypass.down(bypass)

      assert {:error, %{status: nil, code: "network_error", retryable: true, reason: _}} =
               PostHog.deliver(email, config)
    end
  end

  describe "through Swoosh.Mailer" do
    test "deliver/2 sends through the configured adapter", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      expect_body(bypass, shipped_body())

      assert Mailer.deliver(email, config) == {:ok, %{id: @message_id}}
    end

    test "deliver/2 needs an api_key", %{shipped: email} do
      assert_raise ArgumentError, ~r/expected \[:api_key\] to be set/, fn ->
        Mailer.deliver(email, [])
      end
    end
  end
end
