defmodule KbaseBot.LLM.Prompts do
  @moduledoc """
  Compile-time loading of prompt templates from priv/prompts/.
  Mirrors aifred-web's include_str! pattern for skill/prompt files.
  """

  @manager_prompt_path "priv/prompts/manager.md"
  @task_execution_prompt_path "priv/prompts/task_execution.md"
  @briefing_prompt_path "priv/prompts/briefing.md"

  if File.exists?(@manager_prompt_path) do
    @external_resource @manager_prompt_path
    @manager_prompt File.read!(@manager_prompt_path)
  else
    @manager_prompt ""
  end

  if File.exists?(@task_execution_prompt_path) do
    @external_resource @task_execution_prompt_path
    @task_execution_prompt File.read!(@task_execution_prompt_path)
  else
    @task_execution_prompt ""
  end

  if File.exists?(@briefing_prompt_path) do
    @external_resource @briefing_prompt_path
    @briefing_prompt File.read!(@briefing_prompt_path)
  else
    @briefing_prompt ""
  end

  def manager, do: @manager_prompt

  def task_execution(user_profile) do
    String.replace(@task_execution_prompt, "{{user_profile}}", user_profile)
  end

  def briefing(day_of_week, date, user_profile) do
    @briefing_prompt
    |> String.replace("{{day_of_week}}", day_of_week)
    |> String.replace("{{date}}", date)
    |> String.replace("{{user_profile}}", user_profile)
  end
end
