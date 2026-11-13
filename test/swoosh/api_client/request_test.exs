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
