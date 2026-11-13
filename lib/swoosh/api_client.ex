defmodule Swoosh.ApiClient do
  @moduledoc """
  Specification for a Swoosh API client.

  It can be set to your own client with:

      config :swoosh, :api_client, MyAPIClient

  Swoosh comes with `Swoosh.ApiClient.Hackney`, `Swoosh.ApiClient.Finch`, and
  `Swoosh.ApiClient.Req`.
  """

  @type url :: binary()
  @type headers :: [{binary(), binary()}]
  @type body :: binary()
  @type status :: pos_integer()
  @type method :: atom()

  @doc """
  Callback to initializes the given api client.
  """
  @callback init() :: :ok

  @doc """
  Callback invoked when posting to a given URL.
  """
  @callback post(url, headers, body, Swoosh.Email.t()) ::
              {:ok, status, headers, body} | {:error, term()}

  @doc """
  Callback invoked when sending a request with the given method to a given URL.

  Optional: a client without it takes only `:post`, through `c:post/4`.
  Adapters that upload files, such as `Swoosh.Adapters.PostHog`, need it.
  """
  @callback request(method, url, headers, body, Swoosh.Email.t()) ::
              {:ok, status, headers, body} | {:error, term()}

  @optional_callbacks init: 0, request: 5

  @doc """
  API used by adapters to post to a given URL with headers, body, and email.
  """
  def post(url, headers, body, email) do
    api_client().post(url, headers, body, email)
  end

  @doc """
  API used by adapters to send a request with the given method to a given URL
  with headers, body, and email.

  Raises `ArgumentError` when the configured client has no `c:request/5` and
  the method isn't `:post`.
  """
  def request(method, url, headers, body, email) do
    client = api_client()

    cond do
      Code.ensure_loaded?(client) and function_exported?(client, :request, 5) ->
        client.request(method, url, headers, body, email)

      method == :post ->
        client.post(url, headers, body, email)

      true ->
        raise ArgumentError,
              "#{inspect(client)} does not implement request/5, so it can't send " <>
                "#{method |> to_string() |> String.upcase()} requests"
    end
  end

  @doc false
  def init do
    client = api_client()

    if Code.ensure_loaded?(client) and function_exported?(client, :init, 0) do
      :ok = client.init()
    end

    :ok
  end

  defp api_client do
    Application.fetch_env!(:swoosh, :api_client)
  end
end
