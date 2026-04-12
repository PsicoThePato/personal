defmodule KbaseBot.LLM.Client do
  @moduledoc """
  Wraps Anthropix with retry logic and ephemeral cache control.
  Adapted from aifred-web's anthropic.rs retry pattern.
  """

  require Logger

  @max_retries 3
  @retry_base_ms 1_000
  @default_model "claude-sonnet-4-20250514"
  @default_max_tokens 4096

  @doc """
  Send a chat request to Claude with tool definitions.

  Options:
    - :model - model ID (default: claude-sonnet-4-20250514)
    - :max_tokens - max response tokens (default: 4096)
    - :tools - list of tool schemas (Anthropic format)
  """
  def chat(system, messages, opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    tools = Keyword.get(opts, :tools, [])

    # Anthropix expects atom keys in messages and tools
    converted_messages = Enum.map(messages, &atomize_keys/1)
    converted_tools = Enum.map(tools, &deep_atomize_keys/1)

    # Use content block format for system prompt to enable caching
    system_blocks = [
      %{type: "text", text: system, cache_control: %{type: "ephemeral", ttl: "1h"}}
    ]

    anthropix_opts = [
      model: model,
      max_tokens: max_tokens,
      system: system_blocks,
      messages: converted_messages
    ]

    anthropix_opts =
      if converted_tools != [] do
        # Add cache_control to the last tool to cache the entire tool block
        cached_tools = cache_last_tool(converted_tools)
        Keyword.put(anthropix_opts, :tools, cached_tools)
      else
        anthropix_opts
      end

    do_request(anthropix_opts, 0)
  end

  defp cache_last_tool([]), do: []

  defp cache_last_tool(tools) do
    {last, rest} = List.pop_at(tools, -1)
    rest ++ [Map.put(last, :cache_control, %{type: "ephemeral"})]
  end

  defp do_request(opts, attempt) when attempt < @max_retries do
    client = Anthropix.init(api_key())

    case Anthropix.chat(client, opts) do
      {:ok, %{"type" => "error", "error" => %{"type" => error_type}} = error} ->
        if retryable_error?(error_type) do
          retry(opts, attempt, "API error: #{error_type}")
        else
          Logger.error("Non-retryable API error: #{inspect(error)}")
          {:error, {:api_error, error_type, error}}
        end

      {:ok, %{"content" => _content} = response} ->
        {:ok, response}

      {:error, reason} ->
        retry(opts, attempt, "HTTP error: #{inspect(reason)}")
    end
  end

  defp do_request(_opts, _attempt) do
    Logger.error("LLM client: max retries exceeded")
    {:error, :max_retries_exceeded}
  end

  defp retry(opts, attempt, reason) do
    delay = @retry_base_ms * Integer.pow(2, attempt)
    Logger.warning("LLM retry attempt #{attempt + 1}/#{@max_retries}: #{reason}, waiting #{delay}ms")
    Process.sleep(delay)
    do_request(opts, attempt + 1)
  end

  defp retryable_error?(error_type) do
    error_type in ["overloaded_error", "api_error", "rate_limit_error"]
  end

  defp api_key do
    Application.fetch_env!(:kbase_bot, :anthropic_api_key)
  end

  @doc """
  Extract text content from an Anthropic API response.
  """
  def extract_text(%{"content" => content}) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map(& &1["text"])
    |> Enum.join("")
  end

  def extract_text(_), do: ""

  @doc """
  Extract tool use blocks from an Anthropic API response.
  """
  def extract_tool_calls(%{"content" => content}) do
    content
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> Enum.map(fn block ->
      %{
        id: block["id"],
        name: block["name"],
        input: block["input"]
      }
    end)
  end

  def extract_tool_calls(_), do: []

  @doc """
  Check if the response's stop_reason indicates tool use.
  """
  def needs_tool_response?(%{"stop_reason" => "tool_use"}), do: true
  def needs_tool_response?(_), do: false

  # --- Key conversion (Anthropix requires atom keys) ---

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), atomize_value(v)}
      {k, v} -> {k, atomize_value(v)}
    end)
  end

  defp atomize_value(list) when is_list(list), do: Enum.map(list, &atomize_value/1)
  defp atomize_value(map) when is_map(map), do: atomize_keys(map)
  defp atomize_value(other), do: other

  defp deep_atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), deep_atomize_keys(v)}
      {k, v} when is_atom(k) -> {k, deep_atomize_keys(v)}
    end)
  end

  defp deep_atomize_keys(list) when is_list(list), do: Enum.map(list, &deep_atomize_keys/1)
  defp deep_atomize_keys(other), do: other
end
