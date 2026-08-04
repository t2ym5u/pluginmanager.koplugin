-- Optional configuration for pluginmanager.koplugin's "Discover plugins…"
-- feature. Copy this file to pluginmanager_configuration.lua (same folder)
-- and fill in a GitHub personal access token to raise the GitHub Search
-- API's very low unauthenticated rate limit (10 requests/minute).
--
-- Use a classic token, not a fine-grained one -- GitHub's search API does
-- not support fine-grained tokens at all. Create one at:
-- https://github.com/settings/tokens/new
-- No scopes are required for searching/reading public repositories.
--
-- pluginmanager_configuration.lua is gitignored: it is never committed.

return {
    github_token = "ghp_your_token_here",
}
