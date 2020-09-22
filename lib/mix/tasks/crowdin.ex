defmodule Mix.Tasks.Crowdin do
  use Mix.Task
  alias CrowdinElixirAction.Crowdin
  alias CrowdinElixirAction.Github

  def run([workspace]) do
    IO.puts "Mix crowdin task #{inspect workspace}"

    token = System.get_env("INPUT_TOKEN")
    project_id = System.get_env("INPUT_PROJECT_ID")
    source_file = System.get_env("INPUT_SOURCE_FILE")
    update_source = System.get_env("INPUT_UPDATE_SOURCE")
    update_translation = System.get_env("INPUT_UPDATE_TRANSLATION")

    IO.puts "Update source: #{update_source} update translation: #{update_translation}"
    if update_source == "true" do
      update_source(workspace, token, project_id, source_file)
    end
    if update_translation == "true" do
      update_translation(workspace, token, project_id, source_file)
    end
  end

  def find_matching_remote_file(client, project_id, source_name) do
    with {:ok, res} <- Crowdin.list_files(client, project_id),
      200 <- res.status do
      Enum.find(res.body["data"], fn file -> file["data"]["name"] == source_name end)
    end
  end

  def upload_source(workspace, client, project_id, source_file) do
    path = Path.join(workspace, source_file)
    source_name = Path.basename(source_file)
    export_pattern = System.get_env("INPUT_EXPORT_PATTERN")
    IO.puts "Upload source with #{source_name} export pattern: #{export_pattern}"
    with {:ok, res} <- Crowdin.add_storage(client, path),
         201 <- res.status,
         %{"data" => %{"id" => storage_id}} <- res.body do
      case find_matching_remote_file(client, project_id, source_name) do
        nil -> Crowdin.add_file(client, project_id, storage_id, source_name, export_pattern)
        file -> Crowdin.update_file(client, project_id, file["data"]["id"], storage_id)
      end
    end
  end

  def download_translation(workspace, client, project_id, file) do
    IO.puts "Download translation"
    with {:ok, res} <- Crowdin.get_project(client, project_id),
         200 <- res.status,
         %{"data" => %{"targetLanguages" => target_languages}} <- res.body do
      Enum.each(target_languages, fn target_language ->
        case download_translation_for_language(workspace, client, project_id, file, target_language) do
          :ok ->
            IO.puts "Downloaded translation for #{inspect target_language} to #{inspect file}"
          err ->
            IO.puts "Failed to download translation for #{inspect target_language} to #{inspect file} err: #{inspect err}"
        end
      end)
    end
  end

  def download_translation_for_language(workspace, client, project_id, file, target_language) do
    with {:ok, res} <- Crowdin.build_project_file_translation(client, project_id, file["id"], target_language["id"]),
         200 <- res.status,
         %{"data" => %{"url" => url}} <- res.body,
         {:ok, res} <- Tesla.get(url) do
      IO.puts "Download translation for language: #{inspect target_language} to #{inspect file}"
      export_pattern = file["exportOptions"]["exportPattern"]
      target_file_name = translate_file_name(export_pattern, target_language)
      target_path = Path.join(workspace, target_file_name)
      File.mkdir_p(Path.dirname(target_path))
      File.write(target_path, res.body)
    end
  end

  def translate_file_name(export_pattern, target_language) do
    Enum.reduce(target_language, export_pattern, fn {key, value}, acc ->
      if is_binary(value) do
        key = key |> String.replace(~r/([A-Z])/, "_\\1") |> String.downcase()
        String.replace(acc, "%#{key}%", to_string(value))
      else
        acc
      end
    end)
  end

  def create_pr_if_changed(workspace) do
    IO.puts "Create PR if changed"
    File.cd!(workspace)

    localization_branch = "localization"
    github_actor = System.get_env("GITHUB_ACTOR")
    github_token = System.get_env("GITHUB_TOKEN")
    github_repository = System.get_env("GITHUB_REPOSITORY")
    repo_url="https://#{github_actor}:#{github_token}@github.com/#{github_repository}.git"
    System.cmd("git", ["config", "--global", "user.email", "crowdin-elixir-action@kahoot.com"])
    System.cmd("git", ["config", "--global", "user.name", "Crowdin Elixir Action"])
    System.cmd("git", ["checkout", "-b", localization_branch])

    case System.cmd("git", ["status", "--porcelain"]) do
      {"", 0} ->
        IO.puts "No changes of translation"
        :ok
      _ ->
        IO.puts "Push to branch #{localization_branch}"

        System.cmd("git", ["add", "."])
        System.cmd("git", ["commit", "-m", "Update localization"])
        System.cmd("git", ["push", "--force", repo_url])

        base_branch = System.get_env("INPUT_BASE_BRANCH")

        client = Github.client(github_token)
        with {:ok, res} <- Github.get_pulls(client, github_repository, base: base_branch),
             200 <- res.status, [] <- res.body do
          IO.puts "Create PR"
          Github.create_pull_request(client, github_repository, %{title: "Update localization", base: base_branch, head: localization_branch})
        else
          {:error, err} ->
            IO.puts "Got error #{err}"
            {:error, err}
          [_ | _] ->
            IO.puts "PR already exists"
        end
    end
  end

  defp update_source(workspace, token, project_id, source_file) do
    IO.puts "Sync source to crowdin"
    client = Crowdin.client(token)
    upload_source(workspace, client, project_id, source_file)
  end

  defp update_translation(workspace, token, project_id, source_file) do
    IO.puts "Update translation from crowdin"
    client = Crowdin.client(token)
    source_name = Path.basename(source_file)    
    case find_matching_remote_file(client, project_id, source_name) do
      nil ->
        IO.puts "Source doesn't exist on crowdin yet"
      file ->
        download_translation(workspace, client, project_id, file["data"])
        create_pr_if_changed(workspace)
    end
  end
end