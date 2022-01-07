defmodule CrowdinElixirAction do
  alias CrowdinElixirAction.Crowdin
  alias CrowdinElixirAction.Github

  def serialize_value(value) when is_binary(value) do
    normalized_value = value
                       |> String.replace("\n", "\\n")
                       |> String.replace("\t", "\\t")
                       |> String.replace("\"", "\\\"")
    ["\"", normalized_value, "\""]
  end

  def serialize_value(value) do
    value
    |> Enum.sort()
    |> list_to_iodata("    ", "  ")
  end

  def list_to_iodata(list, indent1 \\ "  ", indent2 \\ "") do
    content = Enum.map_intersperse(list, ",\n", fn {key, value} ->
      [indent1, "\"", key, "\": ", serialize_value(value)]
    end)
    ["{\n", content, "\n", indent2, "}"]
  end

  def is_front_end_context() do
    System.get_env("INPUT_FRONT_END_CONTEXT") == "true"
  end

  def translate_string(string) do
    id = string["id"]
    message = string["defaultMessage"]
    description = string["description"]

    case description do
      nil -> {id, %{"message" => message}}
      _ -> {id, %{"message" => message, "description" => description}}
    end
  end

  def combine_path(path, output_path) do
    content = path <> "/**/*.json"
              |> Path.wildcard()
              |> Enum.map(&File.read!/1)
              |> Enum.flat_map(&Jason.decode!/1)
              |> Enum.map(&translate_string/1)
              |> Enum.sort()
              |> list_to_iodata()

    File.write!(output_path, content)
  end

  def parse_source_file(workspace, source_file_val, is_upload_source) do
    [source_file, export_pattern, source_file_name] = case String.split(source_file_val, ":") do
      [source_file] -> [source_file, System.get_env("INPUT_EXPORT_PATTERN"), Path.basename(source_file)]
      [source_file, export_pattern, source_file_name] -> [source_file, export_pattern, source_file_name]
    end

    case is_front_end_context() && is_upload_source do
      false -> [source_file, export_pattern, source_file_name]
      true ->
         path = Path.join(workspace, source_file)
         %File.Stat{type: :directory} = File.stat!(path)
         output_file_name = source_file_name <> ".crowdin"
         output_path = Path.join(workspace, output_file_name)
         combine_path(path, output_path)
         [output_file_name, export_pattern, source_file_name]
    end
  end

  def find_matching_remote_file(client, project_id, source_name) do
    with {:ok, res} <- Crowdin.list_files(client, project_id),
         200 <- res.status do
      Enum.find(res.body["data"], fn file -> file["data"]["name"] == source_name end)
    end
  end

  def upload_source(workspace, client, project_id, source_files) do
    for source_file_val <- source_files do
      [source_file, export_pattern, source_name] = parse_source_file(workspace, source_file_val, true)
      path = Path.join(workspace, source_file)
      IO.puts "Upload source with #{source_name} export pattern: #{export_pattern}"
      with {:ok, %{status: 201, body: body}} <- Crowdin.add_storage(client, path),
           %{"data" => %{"id" => storage_id}} <- body do
        case find_matching_remote_file(client, project_id, source_name) do
          nil -> Crowdin.add_file(client, project_id, storage_id, source_name, export_pattern)
          file ->
            {:ok, %{status: 200} = res} = Crowdin.update_file(client, project_id, file["data"]["id"], storage_id)
            {:ok, res}
        end
      end
    end
  end

  def download_translation(workspace, client, project_id, file, export_pattern) do
    IO.puts "Download translation 2021-05-25"
    {:ok, %{status: 200, body: body}} = Crowdin.get_project(client, project_id)
    target_languages = get_in(body, ["data", "targetLanguages"])
    Enum.each(target_languages, fn target_language ->
      case download_translation_for_language(workspace, client, project_id, file, target_language, export_pattern) do
        :ok ->
          IO.puts "Downloaded translation for language: #{target_language["id"]} of #{file["name"]}"
        err ->
          IO.puts "Failed to download translation err: #{inspect err}"
      end
    end)
  end

  def download_translation_for_language(workspace, client, project_id, file, target_language, export_pattern) do
    with {:ok, %{status: 200, body: body}} <- Crowdin.build_project_file_translation(client, project_id, file["id"], target_language["id"]),
         %{"data" => %{"url" => url}} <- body,
         {:ok, res} <- Tesla.get(url) do
      IO.puts "Download translation for language: #{target_language["id"]} of #{file["name"]}"
      target_file_name = translate_file_name(export_pattern, target_language, file)
      target_path = Path.join(workspace, target_file_name)
      File.mkdir_p(Path.dirname(target_path))
      case is_front_end_context() || project_id == "4" do
        false -> File.write(target_path, res.body)
        true ->
          content = res.body
          |> Jason.decode!()
          |> Enum.map(fn
            {key, value} when is_map(value) ->
              {key, value["message"]}
            {key, value} when is_binary(value) ->
              {key, value}
          end)
          |> Enum.sort()
          |> list_to_iodata()

          File.write(target_path, content)
      end
    end
  end

  def get_kahoot_language_code(target_language) do
    case target_language["locale"] do
      "zh-CN" -> "zh-CN"
      "zh-TW" -> "zh-TW"
      _ -> target_language["twoLettersCode"]
    end
  end

  def translate_file_name(export_pattern, target_language, file) do
    target_language
    |> Enum.reduce(export_pattern, fn {key, value}, acc ->
      if is_binary(value) do
        # "twoLettersCode" -> "two_letters_code"
        key = key |> String.replace(~r/([A-Z])/, "_\\1") |> String.downcase()
        String.replace(acc, "%#{key}%", to_string(value))
      else
        acc
      end
    end)
    |> String.replace("%file_name%", file["name"])
    |> String.replace("%original_file_name%", file["name"])
    |> String.replace("%kahoot_language_code%", get_kahoot_language_code(target_language))
  end

  def switch_to_localization_branch(workspace) do
    localization_branch = "localization"
    File.cd!(workspace)

    IO.puts "Switch to localization branch: #{localization_branch}"
    System.cmd("git", ["remote", "-v"]) |> IO.inspect(label: :remote)
    System.cmd("git", ["fetch", "origin", localization_branch]) |> IO.inspect(label: :fetch)
    case System.cmd("git", ["show-branch", "remotes/origin/#{localization_branch}"]) do
      {_, 128} ->
        IO.puts "Create new #{localization_branch} branch"
        System.cmd("git", ["checkout", "-b", localization_branch])
      {_, 0} ->
        IO.puts "Create #{localization_branch} branch based on origin"
        System.cmd("git", ["checkout", "-b", localization_branch, "remotes/origin/#{localization_branch}"])
    end
  end

  def get_github_api_token() do
    case System.get_env("INPUT_GITHUB_API_TOKEN") do
      "" -> System.get_env("GITHUB_TOKEN")
      nil -> System.get_env("GITHUB_TOKEN")
      token -> token
    end
  end

  def create_pr_if_changed(workspace) do
    IO.puts "Create PR if changed 1"
    File.cd!(workspace)
    System.cmd("git", ["remote", "-v"]) |> IO.inspect(label: :remote)
    localization_branch = "localization"
    github_repository = System.get_env("GITHUB_REPOSITORY")
    System.cmd("git", ["config", "--global", "user.email", "crowdin-elixir-action@kahoot.com"])
    System.cmd("git", ["config", "--global", "user.name", "Crowdin Elixir Action"])

    case System.cmd("git", ["status", "--porcelain"]) do
      {"", 0} ->
        IO.puts "No changes of translation"
        :ok
      result ->
        IO.puts "Push to branch #{localization_branch} #{inspect result}"

        System.cmd("git", ["add", "."])
        System.cmd("git", ["commit", "-m", "Update localization"])
        System.cmd("git", ["push", "origin", localization_branch])

        base_branch = System.get_env("INPUT_BASE_BRANCH")

        client = Github.client(get_github_api_token())
        with {:ok, res} <- Github.get_pulls(client, github_repository, base: base_branch, head: localization_branch),
             200 <- res.status,
             prs <- res.body,
             matching_pr when is_nil(matching_pr) <- Enum.find(prs, fn pr -> pr["head"]["ref"] == localization_branch end) do
          IO.puts "Create PR"
          {:ok, %{status: 201, body: _pr}} = Github.create_pull_request(client, github_repository, %{title: "Update localization", base: base_branch, head: localization_branch})
        else
          {:error, err} ->
            IO.puts "Got error #{err}"
            {:error, err}
          pr ->
            pr_number = pr["number"]
            IO.puts "PR already exists ##{pr_number}"
            Github.delete_localization_label(client, github_repository, pr_number)
            Github.add_localization_label(client, github_repository, pr_number) |> IO.inspect(label: :add_label)
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
    switch_to_localization_branch(workspace)
    for source_file_val <- source_files do
      [source_file, export_pattern, source_name] = parse_source_file(workspace, source_file_val, false)
      IO.puts "Update translation for #{source_file}"
      case find_matching_remote_file(client, project_id, source_name) do
        nil ->
          IO.puts "Source doesn't exist on crowdin yet"
        file ->
          IO.puts "Find matching remote file #{inspect file}"
          download_translation(workspace, client, project_id, file["data"], export_pattern)
      end
    end
    create_pr_if_changed(workspace)
  end
end
