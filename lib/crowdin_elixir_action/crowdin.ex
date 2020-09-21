defmodule CrowdinElixirAction.Crowdin do
  use Tesla

  plug Tesla.Middleware.BaseUrl, "https://crowdin.com/api/v2"
  plug Tesla.Middleware.JSON

  def client(token) do
    middleware = [
      {Tesla.Middleware.Headers, [{"authorization", "Bearer " <> token}]},
    ]

    Tesla.client(middleware)
  end

  def get_project(client, project_id) do
    get(client, "/projects/#{project_id}")
  end

  def list_files(client, project_id) do
    get(client, "/projects/#{project_id}/files")
  end

  # TODO(weih): Support directories
  def add_file(client, project_id, storage_id, name, export_pattern) do
    post(client, "/projects/#{project_id}/files", %{
      storageId: storage_id,
      name: name,
      exportOptions: %{
        exportPattern: export_pattern
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
    post(client, "/projects/#{project_id}/translations/builds/files/#{file_id}", %{
      targetLanguageId: target_language_id
    })
  end
end