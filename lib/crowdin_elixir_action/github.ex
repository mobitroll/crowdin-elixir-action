defmodule CrowdinElixirAction.Github do
  use Tesla

  plug Tesla.Middleware.BaseUrl, "https://api.github.com/"
  plug Tesla.Middleware.JSON
  plug Tesla.Middleware.Headers, [{"accept", "application/vnd.github.v3+json; application/vnd.github.antiope-preview+json; application/vnd.github.shadow-cat-preview+json"}, {"user-agent", "crowdin-elixir-action/1.0"}]
  
  def client(token) do
    middleware = [
      {Tesla.Middleware.Headers, [{"authorization", "token " <> token}]},
    ]

    Tesla.client(middleware)
  end

  def get_pulls(client, repo, query) do
    get(client, "/repos/#{repo}/pulls", query)
  end

  def create_pull_request(client, repo, body) do
    post(client, "/repos/#{repo}/pulls", body)
  end

  def merge_pull_request(client, repo, pull_number) do
    put(client, "/repos/#{repo}/pulls/#{pull_number}/merge", %{
      "commit_title" => "Merge pull request #{pull_number} from #{repo}",
      "commit_message" => "Update localization"
    })
  end

  def add_localization_label(client, repo, issue_number) do
    post(client, "/repos/#{repo}/issues/#{issue_number}/labels", %{
      labels: ["localization"]
    })
  end

  def delete_localization_label(client, repo, issue_number) do
    delete(client, "/repos/#{repo}/issues/#{issue_number}/labels/localization")
  end
end