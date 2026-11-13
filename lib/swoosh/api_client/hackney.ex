defmodule Swoosh.ApiClient.Hackney do
  @moduledoc """
  Built-in hackney-based ApiClient.
  """

  require Logger

  @behaviour Swoosh.ApiClient
  @user_agent {"User-Agent", "swoosh/#{Swoosh.version()}"}

  @impl true
  def init do
    unless Code.ensure_loaded?(:hackney) do
      Logger.error("""
      Could not find hackney dependency.

      Please add :hackney to your dependencies:

          {:hackney, "~> 1.9"}

      Or set your own Swoosh.ApiClient:

          config :swoosh, :api_client, MyAPIClient
      """)

      raise "missing hackney dependency"
    end

    _ = Application.ensure_all_started(:hackney)
    :ok
  end

  @credential_options [:basic_auth, :cookie]

  @impl true
  def post(url, headers, body, %Swoosh.Email{} = email) do
    send_request(:post, url, headers, body, hackney_options(email))
  end

  @impl true
  def request(method, url, headers, body, %Swoosh.Email{} = email) do
    options = Enum.reject(hackney_options(email), &credential?/1)
    send_request(method, url, headers, body, options)
  end

  defp hackney_options(email),
    do: email.private[:hackney_options] || email.private[:client_options] || []

  defp credential?({key, _value}), do: key in @credential_options
  defp credential?(_option), do: false

  defp send_request(method, url, headers, body, hackney_options) do
    :hackney.request(
      method,
      url,
      [@user_agent | headers],
      body,
      [:with_body | hackney_options]
    )
  end
end
