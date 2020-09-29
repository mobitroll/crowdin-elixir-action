defmodule CrowdinElixirAction do
  alias CrowdinElixirAction.Crowdin
  alias CrowdinElixirAction.Github

  def find_matching_remote_file(client, project_id, source_name) do
    with {:ok, res} <- Crowdin.list_files(client, project_id),
         200 <- res.status do
      Enum.find(res.body["data"], fn file -> file["data"]["name"] == source_name end)
    end
  end

  def upload_source(workspace, client, project_id, source_files) do
    for source_file <- source_files do
      path = Path.join(workspace, source_file)
      source_name = Path.basename(source_file)
      export_pattern = System.get_env("INPUT_EXPORT_PATTERN")
      IO.puts "Upload source with #{source_name} export pattern: #{export_pattern}"
      with {:ok, %{status: 201, body: body}} <- Crowdin.add_storage(client, path),
           %{"data" => %{"id" => storage_id}} <- body do
        case find_matching_remote_file(client, project_id, source_name) do
          nil -> Crowdin.add_file(client, project_id, storage_id, source_name, export_pattern)
          file -> Crowdin.update_file(client, project_id, file["data"]["id"], storage_id)
        end
      end
    end
  end

  def download_translation(workspace, client, project_id, file) do
    IO.puts "Download translation"
    with {:ok, %{status: 200, body: body}} <- Crowdin.get_project(client, project_id),
         %{"data" => %{"targetLanguages" => target_languages}} <- body do
      Enum.each(target_languages, fn target_language ->
        case download_translation_for_language(workspace, client, project_id, file, target_language) do
          :ok ->
            IO.puts "Downloaded translation"
          err ->
            IO.puts "Failed to download translation err: #{inspect err}"
        end
      end)
    end
  end

  def download_translation_for_language(workspace, client, project_id, file, target_language) do
    with {:ok, %{status: 200, body: body}} <- Crowdin.build_project_file_translation(client, project_id, file["id"], target_language["id"]),
         %{"data" => %{"url" => url}} <- body,
         {:ok, res} <- Tesla.get(url) do
      IO.puts "Download translation for language: #{inspect target_language} to #{inspect file}"
      export_pattern = file["exportOptions"]["exportPattern"]
      target_file_name = translate_file_name(export_pattern, target_language, file)
      target_path = Path.join(workspace, target_file_name)
      File.mkdir_p(Path.dirname(target_path))
      File.write(target_path, res.body)
    end
  end

  def translate_file_name(export_pattern, target_language, file) do
    target_language
    |> Enum.reduce(export_pattern, fn {key, value}, acc ->
      if is_binary(value) do
        key = key |> String.replace(~r/([A-Z])/, "_\\1") |> String.downcase()
        String.replace(acc, "%#{key}%", to_string(value))
      else
        acc
      end
    end)
    |> String.replace("%file_name%", file["name"])
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
    case System.cmd("git", ["show-branch", "remotes/origin/#{localization_branch}"]) do
      {_, 128} ->
        IO.puts "Create new #{localization_branch} branch"
        System.cmd("git", ["checkout", "-b", localization_branch])
      {_, 0} ->
        IO.puts "Create #{localization_branch} branch based on origin"
        System.cmd("git", ["checkout", "-b", localization_branch, "remotes/origin/#{localization_branch}"])
    end


    case System.cmd("git", ["status", "--porcelain"]) do
      {"", 0} ->
        IO.puts "No changes of translation"
        :ok
      result ->
        IO.puts "Push to branch #{localization_branch} #{inspect result}"

        System.cmd("git", ["add", "."])
        System.cmd("git", ["commit", "-m", "Update localization"])
        System.cmd("git", ["push", "--force", repo_url])

        base_branch = System.get_env("INPUT_BASE_BRANCH")

        client = Github.client(github_token)
        with {:ok, res} <- Github.get_pulls(client, github_repository, base: base_branch, head: localization_branch),
             200 <- res.status,
             prs <- res.body,
             matching_pr when not is_nil(matching_pr) <- Enum.map(prs, fn pr -> pr["head"]["ref"] == localization_branch end) do
          IO.puts "Create PR"
          Github.create_pull_request(client, github_repository, %{title: "Update localization", base: base_branch, head: localization_branch})
        else
          {:error, err} ->
            IO.puts "Got error #{err}"
            {:error, err}
          nil ->
            IO.puts "PR already exists"
        end
    end
  end

  def update_source(workspace, organization, token, project_id, source_files) do
    IO.puts "Sync source to crowdin"
    client = Crowdin.client(organization, token)
    upload_source(workspace, client, project_id, source_files)
  end

  def update_translation(workspace, organization, token, project_id, source_files) do
    IO.puts "Update translation from crowdin"
    client = Crowdin.client(organization, token)
    for source_file <- source_files do
      IO.puts "Update translation for #{source_file}"
      source_name = Path.basename(source_file)
      case find_matching_remote_file(client, project_id, source_name) do
        nil ->
          IO.puts "Source doesn't exist on crowdin yet"
        file ->
          IO.puts "Find matching remote file #{inspect file}"
          download_translation(workspace, client, project_id, file["data"])
      end
    end
    create_pr_if_changed(workspace)
  end
end
