defmodule CrowdinElixirAction.Crowdin do
  use Tesla

  # plug Tesla.Middleware.BaseUrl, "https://crowdin.com/api/v2"
  plug Tesla.Middleware.JSON

  def client(organization_domain, token) do
    middleware = [
      {Tesla.Middleware.BaseUrl, "https://#{organization_domain}.crowdin.com/api/v2"},
      {Tesla.Middleware.Headers, [{"authorization", "Bearer " <> token}]},
    ]

    Tesla.client(middleware)
  end

  def get_project(client, project_id) do
    get(client, "/projects/#{project_id}")
  end

  def list_files(client, project_id, filename) do
    get(client, "/projects/#{project_id}/files", query: [filter: filename])
  end

  # TODO(weih): Support directories
  def add_file(client, project_id, storage_id, name, export_pattern) do
    # Crowdin gives the following message if our in house %kahoot_language_code% is used
    # [exportPattern][exportPattern - If the resulting file name starts with the slash (/), it should contain at least one language identifier to prevent overriding translation in the archive [%language%, %two_letters_code%, %three_letters_code%, %locale%, %locale_with_underscore%, %android_code%, %osx_code%, %osx_locale%]
    normalized_export_pattern = String.replace(export_pattern, "%kahoot_language_code%", "%two_letters_code%")
      |> String.replace("%kahoot_android_language_code%", "%two_letters_code%")
    post(client, "/projects/#{project_id}/files", %{
      storageId: storage_id,
      name: name,
      exportOptions: %{
        exportPattern: normalized_export_pattern
      }
    })
  end

  def update_file(client, project_id, file_id, storage_id) do
    put(client, "/projects/#{project_id}/files/#{file_id}", %{
      storageId: storage_id,
    })
  end

  def add_storage(client, source_file) do
    with {:ok, content} <- File.read(source_file) do
      post(client, "/storages", content, headers: [
                                           {"content-type", "application/octet-stream"},
                                           {"crowdin-api-filename", Path.basename(source_file)}
      ])
    end
  end

  def build_project_file_translation(client, project_id, file_id, target_language_id) do
    skip_untranslated_strings = System.get_env("INPUT_SKIP_UNTRANSLATED_STRINGS") == "true"
#    Crowdin returns 400 if exportApprovedOnly is passed from Nov 1st.
#    export_approved_only = System.get_env("INPUT_EXPORT_APPROVED_ONLY") == "true"
    post(client, "/projects/#{project_id}/translations/builds/files/#{file_id}", %{
      targetLanguageId: target_language_id,
      skipUntranslatedStrings: skip_untranslated_strings
#      exportApprovedOnly: export_approved_only
    })
  end
end
