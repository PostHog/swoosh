defmodule Swoosh.ApiClient.RequestTest do
  # async: false because we change application env
  use ExUnit.Case, async: false

  alias Swoosh.{ApiClient, Email}

  defmodule PostOnlyClient do
    @behaviour Swoosh.ApiClient

    @impl true
    def post(url, _headers, body, _email), do: {:ok, 200, [], "posted #{body} to #{url}"}
  end

  @bytes <<0, 1, 2, 255>>
  @signed_query "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIA%2F20261110%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-SignedHeaders=content-length%3Bhost%3Bx-amz-checksum-sha256&X-Amz-Signature=abc"

  setup do
    api_client = Application.fetch_env!(:swoosh, :api_client)
    finch_name = Application.get_env(:swoosh, :finch_name)

    on_exit(fn ->
      Application.put_env(:swoosh, :api_client, api_client)

      if finch_name,
        do: Application.put_env(:swoosh, :finch_name, finch_name),
        else: Application.delete_env(:swoosh, :finch_name)
    end)

    {:ok, bypass: Bypass.open()}
  end

  defp use_client(Swoosh.ApiClient.Finch = client) do
    start_supervised!({Finch, name: Swoosh.Test.RequestFinch})
    Application.put_env(:swoosh, :finch_name, Swoosh.Test.RequestFinch)
    Application.put_env(:swoosh, :api_client, client)
  end

  defp use_client(client), do: Application.put_env(:swoosh, :api_client, client)

  for client <- [Swoosh.ApiClient.Hackney, Swoosh.ApiClient.Finch, Swoosh.ApiClient.Req] do
    test "#{inspect(client)} sends a PUT with the given headers and the raw body", %{
      bypass: bypass
    } do
      use_client(unquote(client))

      Bypass.expect_once(bypass, "PUT", "/upload", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == @bytes
        assert conn.query_string == @signed_query
        assert Plug.Conn.get_req_header(conn, "content-length") == ["4"]
        assert Plug.Conn.get_req_header(conn, "x-amz-checksum-sha256") == ["c2lnbmVk"]
        assert Plug.Conn.get_req_header(conn, "user-agent") == ["swoosh/#{Swoosh.version()}"]
        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, 200, _headers, ""} =
               ApiClient.request(
                 :put,
                 "http://localhost:#{bypass.port}/upload?#{@signed_query}",
                 [{"content-length", "4"}, {"x-amz-checksum-sha256", "c2lnbmVk"}],
                 @bytes,
                 %Email{}
               )
    end
  end

  # The headers a built-in client may add to a PUT beside the ones it was given. Hackney labels
  # a binary body application/octet-stream, which the presigned URL doesn't sign.
  @transport_headers ["host", "user-agent", "accept-encoding", "connection", "te", "content-type"]

  for {client, label, credentials} <- [
        {Swoosh.ApiClient.Hackney, "no client options", []},
        {Swoosh.ApiClient.Hackney, "basic_auth in hackney_options",
         [hackney_options: [basic_auth: {"app", "secret"}]]},
        {Swoosh.ApiClient.Hackney, "basic_auth in client_options",
         [client_options: [basic_auth: {"app", "secret"}]]},
        {Swoosh.ApiClient.Finch, "no client options", []},
        {Swoosh.ApiClient.Req, "no client options", []},
        {Swoosh.ApiClient.Req, "a bearer auth in client_options",
         [client_options: [auth: {:bearer, "app-secret"}]]},
        {Swoosh.ApiClient.Req, "a basic auth in client_options",
         [client_options: [auth: {:basic, "app:secret"}]]},
        {Swoosh.ApiClient.Hackney, "a cookie in hackney_options",
         [hackney_options: [cookie: "session=app-secret"]]},
        {Swoosh.ApiClient.Req, "aws_sigv4 in client_options",
         [
           client_options: [
             aws_sigv4: [access_key_id: "AKIAAPP", secret_access_key: "app-secret", service: :s3]
           ]
         ]}
      ] do
    test "the PostHog upload through #{inspect(client)} with #{label} carries only PostHog's headers",
         %{bypass: bypass} do
      use_client(unquote(client))

      email =
        Enum.reduce(unquote(Macro.escape(credentials)), posthog_email(), fn {key, value}, email ->
          Email.put_private(email, key, value)
        end)

      expect_posthog_upload(bypass)

      assert {:ok, _} = Swoosh.Adapters.PostHog.deliver(email, posthog_config(bypass))
    end
  end

  for {label, defaults} <- [
        {"auth", [auth: {:bearer, "app-secret"}]},
        {"an authorization header", [headers: [{"authorization", "Bearer app-secret"}]]}
      ] do
    test "the PostHog upload through Req carries only PostHog's headers with app-wide Req #{label}",
         %{bypass: bypass} do
      use_client(Swoosh.ApiClient.Req)
      defaults = Req.default_options()
      Req.default_options(unquote(Macro.escape(defaults)))
      on_exit(fn -> Req.default_options(defaults) end)

      expect_posthog_upload(bypass)

      assert {:ok, _} = Swoosh.Adapters.PostHog.deliver(posthog_email(), posthog_config(bypass))
    end
  end

  defp posthog_email do
    Swoosh.Email.new(to: "ana@example.com", subject: "Invoice", text_body: "Attached.")
    |> Swoosh.Email.attachment(Swoosh.Attachment.new({:data, @bytes}, filename: "invoice.pdf"))
  end

  defp posthog_config(bypass),
    do: [api_key: "phs_test", base_url: "http://localhost:#{bypass.port}"]

  defp expect_posthog_upload(bypass) do
    sha256 = :sha256 |> :crypto.hash(@bytes) |> Base.encode16(case: :lower)
    upload_headers = %{"Content-Length" => "4", "x-amz-checksum-sha256" => "c2lnbmVk"}

    Bypass.expect_once(
      bypass,
      "POST",
      "/api/projects/@current/messaging/attachments/uploads/",
      fn conn ->
        answer = %{
          "files" => [
            %{
              "sha256" => sha256,
              "status" => "upload",
              "method" => "PUT",
              "url" => "http://localhost:#{bypass.port}/s3/invoice?#{@signed_query}",
              "headers" => upload_headers
            }
          ]
        }

        Plug.Conn.resp(conn, 200, Jason.encode!(answer))
      end
    )

    Bypass.expect_once(bypass, "PUT", "/s3/invoice", fn conn ->
      names = Enum.map(conn.req_headers, &elem(&1, 0))
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      assert Plug.Conn.get_req_header(conn, "content-length") == ["4"]
      assert Plug.Conn.get_req_header(conn, "x-amz-checksum-sha256") == ["c2lnbmVk"]
      assert names -- (@transport_headers ++ ["content-length", "x-amz-checksum-sha256"]) == []
      Plug.Conn.resp(conn, 200, "")
    end)

    Bypass.expect_once(bypass, "POST", "/api/projects/@current/messaging/send/email/", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer phs_test"]
      Plug.Conn.resp(conn, 202, ~s({"message_id": "msg_1"}))
    end)
  end

  test "a client without request/5 still takes POST requests" do
    use_client(PostOnlyClient)

    assert ApiClient.request(:post, "http://example.com/send", [], "{}", %Email{}) ==
             {:ok, 200, [], "posted {} to http://example.com/send"}
  end

  test "a client without request/5 raises for any other method" do
    use_client(PostOnlyClient)

    assert_raise ArgumentError, ~r/PostOnlyClient does not implement request\/5/, fn ->
      ApiClient.request(:put, "http://example.com/upload", [], @bytes, %Email{})
    end
  end

  test "the PostHog adapter refuses attachments before any request when the client can't PUT", %{
    bypass: bypass
  } do
    use_client(PostOnlyClient)

    email =
      Swoosh.Email.new(to: "ana@example.com", subject: "Invoice", text_body: "Attached.")
      |> Swoosh.Email.attachment(Swoosh.Attachment.new({:data, "%PDF"}, filename: "invoice.pdf"))

    config = [api_key: "phs_test", base_url: "http://localhost:#{bypass.port}"]

    assert Swoosh.Adapters.PostHog.deliver(email, config) ==
             {:error, {:unsupported, :api_client_cannot_upload}}
  end
end
