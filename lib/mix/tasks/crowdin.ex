defmodule Mix.Tasks.Crowdin do
  use Mix.Task

  defp get_crowdin_token() do
    case System.get_env("INPUT_CROWDIN_TOKEN") do
      val when val in [nil, ""] -> System.get_env("INPUT_TOKEN")
      val -> val
    end
  end

  def run([workspace]) do
    IO.puts "Mix crowdin task #{inspect workspace}"

    organization = System.get_env("INPUT_ORGANIZATION")
    token = get_crowdin_token()
    project_id = System.get_env("INPUT_PROJECT_ID")
    source_file = System.get_env("INPUT_SOURCE_FILE")
    update_source = System.get_env("INPUT_UPDATE_SOURCE")
    update_translation = System.get_env("INPUT_UPDATE_TRANSLATION")

    source_files = String.split(source_file, ",")
    if update_source == "true" do
      IO.puts "Update source: #{update_source} update translation: #{update_translation} source_files: #{inspect source_files}"
      CrowdinElixirAction.update_source(workspace, organization, token, project_id, source_files) |> IO.inspect(label: :update_source)
    end
    if update_translation == "true" do
      IO.puts "Update translation: #{update_source} update translation: #{update_translation} source_files: #{inspect source_files}"
      CrowdinElixirAction.update_translation(workspace, organization, token, project_id, source_files) |> IO.inspect(label: :update_translation)
    end
  end


end