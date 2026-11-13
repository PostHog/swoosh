defmodule Swoosh.Adapters.PostHogTest do
  use Swoosh.AdapterCase, async: true

  import Swoosh.Email
  import Plug.Conn, only: [get_req_header: 2]
  alias Swoosh.Adapters.PostHog

  defmodule Mailer do
    use Swoosh.Mailer, otp_app: :swoosh, adapter: Swoosh.Adapters.PostHog
  end

  @send_path "/api/projects/@current/messaging/send/email/"
  @message_id "0190f0c2-1111-7a3b-9c2e-5f1a2b3c4d5e"
  @template_id "0190f0c2-7d1e-7a3b-9c2e-5f1a2b3c4d5e"
  @uploads_path "/api/projects/@current/messaging/attachments/uploads/"
  @pdf Base.decode64!("JVBERi0xLjQK")
  @png Base.decode64!("iVBORw0KGgo=")

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
      assert [integration] = get_req_header(conn, "x-posthog-integration")
      assert integration =~ ~r|\Aswoosh/[0-9A-Za-z.+-]{1,40}\z|
      assert get_req_header(conn, "idempotency-key") == []
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

  describe "rendered form" do
    test "case 01: sends a minimal rendered email and returns its message id", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      expect_send(bypass, fn conn ->
        assert get_req_header(conn, "authorization") == ["Bearer phs_test"]
        assert get_req_header(conn, "content-type") == ["application/json"]
        assert get_req_header(conn, "x-posthog-integration") == ["swoosh/#{Swoosh.version()}"]
        assert get_req_header(conn, "idempotency-key") == []
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
        |> put_provider_option(:tracking, %{opens: false, clicks: false})
        |> put_provider_option(:sensitive, true)

      expect_send(bypass, fn conn ->
        assert get_req_header(conn, "idempotency-key") == ["order-981-shipped"]

        assert conn.body_params ==
                 shipped_body(%{
                   "template_key" => "order-shipped",
                   "distinct_id" => "user_42",
                   "tracking" => %{"opens" => false, "clicks" => false},
                   "sensitive" => true
                 })
      end)

      assert {:ok, _} = PostHog.deliver(email, config)
    end

    for {tracking, sensitive} <- [{false, false}, {true, true}] do
      test "sends tracking: #{tracking} and sensitive: #{sensitive} as given", %{
        bypass: bypass,
        config: config,
        shipped: email
      } do
        email =
          email
          |> put_provider_option(:tracking, unquote(tracking))
          |> put_provider_option(:sensitive, unquote(sensitive))

        expect_body(
          bypass,
          shipped_body(%{"tracking" => unquote(tracking), "sensitive" => unquote(sensitive)})
        )

        assert {:ok, _} = PostHog.deliver(email, config)
      end
    end

    test "never sends capture_engagement, which tracking replaces", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      email =
        email
        |> put_provider_option(:tracking, %{engagement: false})
        |> put_provider_option(:capture_engagement, true)

      expect_body(bypass, shipped_body(%{"tracking" => %{"engagement" => false}}))

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

    test "sends an internationalized domain in Punycode, as PostHog verifies and takes it", %{
      bypass: bypass,
      config: config
    } do
      email =
        new()
        |> from({"Shop", "shop@bücher.example"})
        |> to("ana@bücher.example")
        |> cc("bo@bücher.example")
        |> bcc("audit@bücher.example")
        |> reply_to("help@bücher.example")
        |> subject("Your order shipped")
        |> text_body("On its way.")

      expect_body(bypass, %{
        "from" => "Shop <shop@xn--bcher-kva.example>",
        "to" => "ana@xn--bcher-kva.example",
        "cc" => ["bo@xn--bcher-kva.example"],
        "bcc" => ["audit@xn--bcher-kva.example"],
        "reply_to" => ["help@xn--bcher-kva.example"],
        "subject" => "Your order shipped",
        "text" => "On its way.",
        "template_key" => "swoosh"
      })

      assert {:ok, _} = PostHog.deliver(email, config)
    end

    test "sends a sender without a name in Punycode too", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      expect_body(bypass, shipped_body(%{"from" => "shop@xn--bcher-kva.example"}))

      assert {:ok, _} = PostHog.deliver(from(email, "shop@bücher.example"), config)
    end

    for {label, domain, sent} <- [
          {"an uppercase internationalized domain in lowercase Punycode", "BÜCHER.example",
           "xn--bcher-kva.example"},
          {"an ASCII domain as given, even one IDNA disallows", "Exa_mple.COM", "Exa_mple.COM"},
          {"a domain IDNA can't encode as given, for PostHog to refuse", "😀.example", "😀.example"}
        ] do
      test "sends #{label}", %{bypass: bypass, config: config, shipped: email} do
        expect_body(bypass, shipped_body(%{"to" => "ana@" <> unquote(sent)}))

        assert {:ok, _} =
                 PostHog.deliver(to(%{email | to: []}, "ana@" <> unquote(domain)), config)
      end
    end

    test "takes a template key of 256 characters, the most PostHog takes", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      key = String.duplicate("k", 256)
      expect_body(bypass, shipped_body(%{"template_key" => key}))

      assert {:ok, _} = PostHog.deliver(put_provider_option(email, :template_key, key), config)
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

    test "sends the recipient's internationalized domain in Punycode", %{
      bypass: bypass,
      config: config
    } do
      email = new() |> to("ana@bücher.example") |> put_provider_option(:template, @template_id)

      expect_body(bypass, %{"to" => "ana@xn--bcher-kva.example", "template_id" => @template_id})

      assert {:ok, _} = PostHog.deliver(email, config)
    end

    test "leaves out tracking and sensitive, since the template sets them", %{
      bypass: bypass,
      config: config
    } do
      email =
        new()
        |> to("ana@example.com")
        |> put_provider_option(:template, @template_id)
        |> put_provider_option(:tracking, %{opens: true, clicks: false})
        |> put_provider_option(:sensitive, true)

      expect_body(bypass, %{"to" => "ana@example.com", "template_id" => @template_id})

      assert {:ok, _} = PostHog.deliver(email, config)
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

  describe "attachments" do
    setup %{bypass: bypass} do
      {:ok, uploads: "http://localhost:#{bypass.port}/s3/"}
    end

    test "case 04: uploads each file PostHog lacks, then sends the files by hash", %{
      bypass: bypass,
      config: config,
      shipped: email,
      uploads: uploads
    } do
      invoice =
        Swoosh.Attachment.new({:data, @pdf},
          filename: "invoice.pdf",
          content_type: "application/pdf"
        )

      logo =
        Swoosh.Attachment.new({:data, @png},
          filename: "logo.png",
          content_type: "image/png",
          type: :inline,
          cid: "logo"
        )

      email = %{html_body(email, ~s(<img src="cid:logo">)) | attachments: [invoice, logo]}
      test_pid = self()

      Bypass.expect_once(bypass, "POST", @uploads_path, fn conn ->
        conn = parse(conn)
        send(test_pid, {:request, :ask})
        assert get_req_header(conn, "authorization") == ["Bearer phs_test"]
        assert get_req_header(conn, "x-posthog-integration") == ["swoosh/#{Swoosh.version()}"]
        assert conn.body_params == %{"files" => [file(@pdf), file(@png)]}
        json(conn, 200, %{"files" => [to_upload(@pdf, uploads <> "invoice"), present(@png)]})
      end)

      Bypass.expect_once(bypass, "PUT", "/s3/invoice", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, :upload})
        assert body == @pdf
        assert conn.query_string == "X-Amz-Signature=abc"
        assert get_req_header(conn, "content-length") == ["#{byte_size(@pdf)}"]
        assert get_req_header(conn, "x-amz-checksum-sha256") == [checksum(@pdf)]
        assert get_req_header(conn, "authorization") == []
        assert get_req_header(conn, "x-posthog-integration") == []
        Plug.Conn.resp(conn, 200, "")
      end)

      expect_send(bypass, fn conn ->
        send(test_pid, {:request, :send})

        assert conn.body_params ==
                 shipped_body(%{
                   "html" => ~s(<img src="cid:logo">),
                   "attachments" => [
                     %{
                       "sha256" => sha256(@pdf),
                       "filename" => "invoice.pdf",
                       "content_type" => "application/pdf"
                     },
                     %{
                       "sha256" => sha256(@png),
                       "filename" => "logo.png",
                       "content_type" => "image/png",
                       "content_id" => "logo"
                     }
                   ]
                 })
      end)

      assert PostHog.deliver(email, config) == {:ok, %{id: @message_id}}
      assert requests() == [:ask, :upload, :send]
    end

    test "asks once for a file that two attachments share, and leaves out an unset content type",
         %{bypass: bypass, config: config, shipped: email} do
      email = %{
        email
        | attachments: [
            Swoosh.Attachment.new({:data, @pdf}, filename: "copy-1"),
            Swoosh.Attachment.new({:data, @pdf}, filename: "copy-2")
          ]
      }

      Bypass.expect_once(bypass, "POST", @uploads_path, fn conn ->
        conn = parse(conn)
        assert conn.body_params == %{"files" => [file(@pdf)]}
        json(conn, 200, %{"files" => [present(@pdf)]})
      end)

      expect_body(
        bypass,
        shipped_body(%{
          "attachments" => [
            %{"sha256" => sha256(@pdf), "filename" => "copy-1"},
            %{"sha256" => sha256(@pdf), "filename" => "copy-2"}
          ]
        })
      )

      assert {:ok, _} = PostHog.deliver(email, config)
    end

    test "names an unnamed attachment after its content type, since PostHog needs a filename",
         %{bypass: bypass, config: config, shipped: email} do
      email = %{
        email
        | attachments: [
            Swoosh.Attachment.new({:data, @pdf}, content_type: "application/pdf"),
            Swoosh.Attachment.new({:data, @png})
          ]
      }

      Bypass.expect_once(bypass, "POST", @uploads_path, fn conn ->
        json(conn, 200, %{"files" => [present(@pdf), present(@png)]})
      end)

      expect_body(
        bypass,
        shipped_body(%{
          "attachments" => [
            %{
              "sha256" => sha256(@pdf),
              "filename" => "attachment.pdf",
              "content_type" => "application/pdf"
            },
            %{"sha256" => sha256(@png), "filename" => "attachment"}
          ]
        })
      )

      assert {:ok, _} = PostHog.deliver(email, config)
    end

    @expired "<Error><Code>AccessDenied</Code><Message>Request has expired</Message></Error>"
    @denied "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>"
    @nope "<Error><Code>Nope</Code></Error>"

    for {label, status, body, retryable} <- [
          {"an expired upload URL", 403, @expired, true},
          {"any other 403", 403, @denied, false},
          {"a storage 429", 429, @nope, true},
          {"a storage 500", 500, @nope, true},
          {"a storage 502", 502, @nope, true},
          {"a storage 503", 503, @nope, true},
          {"a storage 504", 504, @nope, true},
          {"a storage 400", 400, @nope, false}
        ] do
      test "#{label} returns upload_failed, retryable: #{retryable}, and sends nothing",
           %{bypass: bypass, config: config, shipped: email, uploads: uploads} do
        email = attachment(email, Swoosh.Attachment.new({:data, @pdf}, filename: "invoice.pdf"))

        Bypass.expect_once(bypass, "POST", @uploads_path, fn conn ->
          json(conn, 200, %{"files" => [to_upload(@pdf, uploads <> "invoice")]})
        end)

        Bypass.expect_once(bypass, "PUT", "/s3/invoice", fn conn ->
          Plug.Conn.resp(conn, unquote(status), unquote(body))
        end)

        assert PostHog.deliver(email, config) ==
                 {:error,
                  %{
                    status: unquote(status),
                    code: "upload_failed",
                    detail: unquote(body),
                    attr: nil,
                    retryable: unquote(retryable),
                    retry_after: nil
                  }}
      end
    end

    test "an upload that can't reach its host is a retryable network error", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      email = attachment(email, Swoosh.Attachment.new({:data, @pdf}, filename: "invoice.pdf"))
      storage = Bypass.open()
      Bypass.down(storage)

      Bypass.expect_once(bypass, "POST", @uploads_path, fn conn ->
        json(conn, 200, %{"files" => [to_upload(@pdf, "http://localhost:#{storage.port}/x")]})
      end)

      assert {:error, %{status: nil, code: "network_error", retryable: true}} =
               PostHog.deliver(email, config)
    end

    test "an upload method the adapter doesn't know returns an error and sends nothing", %{
      bypass: bypass,
      config: config,
      shipped: email,
      uploads: uploads
    } do
      email = attachment(email, Swoosh.Attachment.new({:data, @pdf}, filename: "invoice.pdf"))

      Bypass.expect_once(bypass, "POST", @uploads_path, fn conn ->
        answer = Map.put(to_upload(@pdf, uploads <> "invoice"), "method", "POST")
        json(conn, 200, %{"files" => [answer]})
      end)

      assert {:error, %{status: nil, code: "upload_failed", retryable: false}} =
               PostHog.deliver(email, config)
    end

    for {label, answer} <- [
          {"without files", %{}},
          {"with an unknown status", %{"files" => [%{"status" => "later"}]}}
        ] do
      test "an upload route answer #{label} returns upload_failed and sends nothing", %{
        bypass: bypass,
        config: config,
        shipped: email
      } do
        email = attachment(email, Swoosh.Attachment.new({:data, @pdf}, filename: "invoice.pdf"))

        Bypass.expect_once(bypass, "POST", @uploads_path, fn conn ->
          json(conn, 200, unquote(Macro.escape(answer)))
        end)

        assert {:error, %{status: nil, code: "upload_failed", retryable: false}} =
                 PostHog.deliver(email, config)
      end
    end

    for {label, status, body} <- [
          {"a proxy's page", 200, "<html>Down for maintenance</html>"},
          {"an empty body", 204, ""}
        ] do
      test "an upload route success with #{label} is a retryable invalid_response, and sends nothing",
           %{bypass: bypass, config: config, shipped: email} do
        email = attachment(email, Swoosh.Attachment.new({:data, @pdf}, filename: "invoice.pdf"))

        Bypass.expect_once(bypass, "POST", @uploads_path, fn conn ->
          Plug.Conn.resp(conn, unquote(status), unquote(body))
        end)

        assert PostHog.deliver(email, config) ==
                 {:error,
                  %{
                    status: unquote(status),
                    code: "invalid_response",
                    detail: unquote(body),
                    attr: nil,
                    retryable: true,
                    retry_after: nil
                  }}
      end
    end

    test "a network error on the upload route says the email wasn't sent", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      email = attachment(email, Swoosh.Attachment.new({:data, @pdf}, filename: "invoice.pdf"))
      Bypass.down(bypass)

      assert {:error,
              %{
                status: nil,
                code: "network_error",
                detail: "The request to PostHog failed, so the email wasn't sent.",
                retryable: true
              }} = PostHog.deliver(email, config)
    end

    test "an error from the upload route returns the API error and sends nothing", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      email = attachment(email, Swoosh.Attachment.new({:data, @pdf}, filename: "invoice.pdf"))

      Bypass.expect_once(bypass, "POST", @uploads_path, fn conn ->
        Plug.Conn.resp(conn, 400, api_error("message_too_large", "Too big.", "files__0__size"))
      end)

      assert PostHog.deliver(email, config) ==
               {:error,
                %{
                  status: 400,
                  code: "message_too_large",
                  detail: "Too big.",
                  attr: "files__0__size",
                  retryable: false,
                  retry_after: nil
                }}
    end

    test "429 upload_quota_exceeded is not retryable", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      email = attachment(email, Swoosh.Attachment.new({:data, @pdf}, filename: "invoice.pdf"))

      Bypass.expect_once(bypass, "POST", @uploads_path, fn conn ->
        Plug.Conn.resp(conn, 429, api_error("upload_quota_exceeded", "Try tomorrow."))
      end)

      assert {:error, %{status: 429, code: "upload_quota_exceeded", retryable: false}} =
               PostHog.deliver(email, config)
    end
  end

  defp file(bytes), do: %{"sha256" => sha256(bytes), "size" => byte_size(bytes)}

  defp present(bytes),
    do: %{
      "sha256" => sha256(bytes),
      "status" => "present",
      "expires_at" => "2026-12-16T09:00:00Z"
    }

  defp to_upload(bytes, url) do
    %{
      "sha256" => sha256(bytes),
      "status" => "upload",
      "url" => url <> "?X-Amz-Signature=abc",
      "method" => "PUT",
      "headers" => %{
        "Content-Length" => "#{byte_size(bytes)}",
        "x-amz-checksum-sha256" => checksum(bytes)
      },
      "url_expires_at" => "2026-11-10T09:15:00Z"
    }
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  defp checksum(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode64()

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp requests do
    receive do
      {:request, request} -> [request | requests()]
    after
      0 -> []
    end
  end

  describe "refusals" do
    test "case 08: refuses an explicit template key PostHog can't take", %{
      config: config,
      shipped: email
    } do
      email = put_provider_option(email, :template_key, "order shipped!")

      assert PostHog.deliver(email, config) == {:error, {:unsupported, :invalid_template_key}}
    end

    test "refuses a template key set to false instead of falling back to the default", %{
      config: config,
      shipped: email
    } do
      email = put_provider_option(email, :template_key, false)

      assert PostHog.deliver(email, config) == {:error, {:unsupported, :invalid_template_key}}
    end

    test "refuses a template key over 256 characters", %{config: config, shipped: email} do
      email = put_provider_option(email, :template_key, String.duplicate("k", 257))

      assert PostHog.deliver(email, config) == {:error, {:unsupported, :invalid_template_key}}
    end

    test "refuses a configured default template key PostHog can't take", %{
      config: config,
      shipped: email
    } do
      config = Keyword.put(config, :default_template_key, "order shipped!")

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
          {400, "clicks_need_opens"},
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

    test "a success without a message id is a retryable error, not a sent email", %{
      bypass: bypass,
      config: config,
      shipped: email
    } do
      respond_with(bypass, 200, "<html>Down for maintenance</html>")

      assert PostHog.deliver(email, config) ==
               {:error,
                %{
                  status: 200,
                  code: "invalid_response",
                  detail: "<html>Down for maintenance</html>",
                  attr: nil,
                  retryable: true,
                  retry_after: nil
                }}
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

    for base_url <- ["us.posthog.com", "ftp://us.posthog.com", "https://"] do
      test "deliver/2 raises for the base_url #{base_url} before any request", %{
        config: config,
        shipped: email
      } do
        assert_raise ArgumentError, ~r/base_url must be an http or https URL/, fn ->
          Mailer.deliver(email, Keyword.put(config, :base_url, unquote(base_url)))
        end
      end
    end

    test "deliver/2 needs an api_key", %{shipped: email} do
      assert_raise ArgumentError, ~r/expected \[:api_key\] to be set/, fn ->
        Mailer.deliver(email, [])
      end
    end
  end
end
