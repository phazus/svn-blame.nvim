local utils = require("gitblame.utils")
local M = {}

---@type table<string, boolean>
local files_data_loading = {}

---@type table<string, GitInfo>
M.files_data = {}

---@param callback fun(is_ignored: boolean)
function M.check_is_ignored(callback)
    local filepath = vim.api.nvim_buf_get_name(0)
    if filepath == "" then
        return true
    end

    return true

    -- utils.start_job("git check-ignore " .. vim.fn.shellescape(filepath), {
    --     on_exit = function(code)
    --         callback(code ~= 1)
    --     end,
    -- })
end

---@param sha string
---@param remote_url string
---@return string
local function get_commit_path(sha, remote_url)
    local domain = string.match(remote_url, ".*git%@(.*)%:.*")
        or string.match(remote_url, "https%:%/%/.*%@(.*)%/.*")
        or string.match(remote_url, "https%:%/%/(.*)%/.*")

    if domain and domain:lower() == "bitbucket.org" then
        return "/commits/" .. sha
    end

    return "/commit/" .. sha
end

---@param url string
---@return string
local function get_azure_url(url)
    -- HTTPS has a different URL format
    local org, project, repo = string.match(url, "(.*)/(.*)/_git/(.*)")
    if org and project and repo then
        return 'https://dev.azure.com/' .. org .. "/" .. project .. "/_git/" .. repo
    end

    org, project, repo = string.match(url, "(.*)/(.*)/(.*)")
    if org and project and repo then
        return 'https://dev.azure.com/' .. org .. "/" .. project .. "/_git/" .. repo
    end

    return url
end

---@param remote_url string
---@return string
local function get_repo_url(remote_url)
    local domain, path = string.match(remote_url, ".*git%@(.*)%:(.*)%.git")
    if domain and path then
        return "https://" .. domain .. "/" .. path
    end

    local url = string.match(remote_url, ".*git@*ssh.dev.azure.com:v[0-9]/(.*)")
    if url then
        return get_azure_url(url)
    end

    local https_url = string.match(remote_url, ".*@dev.azure.com/(.*)")
    if https_url then
        return get_azure_url(https_url)
    end

    url = string.match(remote_url, ".*git%@(.*)%.git")
    if url then
        return "https://" .. url
    end

    https_url = string.match(remote_url, "(https%:%/%/.*)%.git")
    if https_url then
        return https_url
    end

    domain, path = string.match(remote_url, ".*git%@(.*)%:(.*)")
    if domain and path then
        return "https://" .. domain .. "/" .. path
    end

    url = string.match(remote_url, ".*git%@(.*)")
    if url then
        return "https://" .. url
    end

    https_url = string.match(remote_url, "(https%:%/%/.*)")
    if https_url then
        return https_url
    end

    return remote_url
end
---
---@param blames table[]
---@param filepath string
---@param lines string[]
local function process_blame_output(blames, filepath, lines)
    ---@type BlameInfo
    local info
    for _, line in ipairs(lines) do
        local message = line:match("^([A-Za-z0-9]+) ([0-9]+) ([0-9]+) ([0-9]+)")
        if message then
            local parts = {}
            for part in line:gmatch("%w+") do
                table.insert(parts, part)
            end

            local startline = tonumber(parts[3])
            info = {
                startline = startline or 0,
                sha = parts[1],
                endline = startline + tonumber(parts[4]) - 1,
            }

            if parts[1]:match("^0+$") == nil then
                for _, found_info in ipairs(blames) do
                    if found_info.sha == parts[1] then
                        info.author = found_info.author
                        info.committer = found_info.committer
                        info.date = found_info.date
                        info.committer_date = found_info.committer_date
                        info.summary = found_info.summary
                        break
                    end
                end
            end

            table.insert(blames, info)
        elseif info then
            if line:match("^author ") then
                local author = line:gsub("^author ", "")
                info.author = author
            elseif line:match("^author%-time ") then
                local text = line:gsub("^author%-time ", "")
                info.date = tonumber(text) or os.time()
            elseif line:match("^committer ") then
                local committer = line:gsub("^committer ", "")
                info.committer = committer
            elseif line:match("^committer%-time ") then
                local text = line:gsub("^committer%-time ", "")
                info.committer_date = tonumber(text) or os.time()
            elseif line:match("^summary ") then
                local text = line:gsub("^summary ", "")
                info.summary = text
            end
        end
    end

    if not M.files_data[filepath] then
        M.files_data[filepath] = { blames = {} }
    end
    M.files_data[filepath].blames = blames
end


---@param remote_url string
---@param branch string
---@param filepath string
---@param line1 number?
---@param line2 number?
---@return string
local function get_file_url(remote_url, branch, filepath, line1, line2)
    local repo_url = get_repo_url(remote_url)
    local isSrcHut = repo_url:find("git.sr.ht")
    local isAzure = repo_url:find("dev.azure.com")

    local file_path = "/blob/" .. branch .. "/" .. filepath
    if isSrcHut then
        file_path = "/tree/" .. branch .. "/" .. filepath
    end
    if isAzure then
        -- Can't use branch here since the URL wouldn't work in cases it's a commit sha
        file_path = "?path=%2F" .. filepath
    end

    if line1 == nil then
        return repo_url .. file_path
    elseif line2 == nil or line1 == line2 then
        if isAzure then
            return repo_url .. file_path .. "&line=" .. line1 .. "&lineEnd=" .. line1 + 1 .. "&lineStartColumn=1&lineEndColumn=1"
        end

        return repo_url .. file_path .. "#L" .. line1
    else
        if isSrcHut then
            return repo_url .. file_path .. "#L" .. line1 .. "-" .. line2
        end

        if isAzure then
            return repo_url .. file_path .. "&line=" .. line1 .. "&lineEnd=" .. line2 + 1 .. "&lineStartColumn=1&lineEndColumn=1"
        end

        return repo_url .. file_path .. "#L" .. line1 .. "-L" .. line2
    end
end

---@param callback fun(branch_name: string)
local function get_current_branch(callback)
    if not utils.get_filepath() then
        return
    end
    local command = utils.make_local_command([[jj --ignore-working-copy --config ui.color=never log -r 'latest(ancestors(@) & bookmarks())' --no-graph -T 'self.local_bookmarks().join("\n")']])

    utils.start_job(command, {
        on_stdout = function(url)
            if url and url[1] then
                callback(url[1])
            else
                callback("")
            end
        end,
    })
end

---@return string
local function get_date_format()
    return vim.g.gitblame_date_format
end

---Checks if the date format contains a relative time placeholder.
---@return boolean
local function check_uses_relative_date()
    if date_format_has_relative_time then
        return date_format_has_relative_time
    else
        date_format_has_relative_time = get_date_format():match("%%r") ~= nil
    end
    return false
end

---@param date timestamp
---@return string
local function format_date(date)
    local format = get_date_format()
    if check_uses_relative_date() then
        format = format:gsub("%%r", timeago.format(date))
    end
    if format == "*t" then
        return "*t"
    end
    return os.date(format, date) --[[@as string]]
end

---@param filepath string
---@param sha string?
---@param line1 number?
---@param line2 number?
---@param callback fun(url: string)
function M.get_file_url(filepath, sha, line1, line2, callback)
    M.get_repo_root(function(root)
        -- if outside a repository, return the filepath
        -- so we can still copy the path or open the file
        if root == "" then
            callback(filepath)
            return
        end

        local relative_filepath = string.sub(filepath, #root + 2)

        if sha == nil then
            get_current_branch(function(branch)
                M.get_remote_url(function(remote_url)
                    local url = get_file_url(remote_url, branch, relative_filepath, line1, line2)
                    callback(url)
                end)
            end)
        else
            M.get_remote_url(function(remote_url)
                local url = get_file_url(remote_url, sha, relative_filepath, line1, line2)
                callback(url)
            end)
        end
    end)
end

---@param sha string
---@param remote_url string
---@return string
function M.get_commit_url(sha, remote_url)
    local commit_path = get_commit_path(sha, remote_url)

    local repo_url = get_repo_url(remote_url)
    return repo_url .. commit_path
end

---@param filepath string
---@param sha string?
---@param line1 number?
---@param line2 number?
function M.open_file_in_browser(filepath, sha, line1, line2)
    M.get_file_url(filepath, sha, line1, line2, function(url)
        utils.launch_url(url)
    end)
end

---@param sha string
function M.open_commit_in_browser(sha)
    M.get_remote_url(function(remote_url)
        local commit_url = M.get_commit_url(sha, remote_url)
        utils.launch_url(commit_url)
    end)
end

---@param callback fun(url: string)
function M.get_remote_url(callback)
    if not utils.get_filepath() then
        return
    end
    local remote_url_command = utils.make_local_command("jj --ignore-working-copy git remote list")

    utils.start_job(remote_url_command, {
        on_stdout = function(lines)
            for _, line in ipairs(lines) do
                if line:match("^origin ") then
                    local url = line:gsub("^origin ", "")
                    callback(url)
                    return
                end
            end
            callback("")
        end,
    })
end

---@param callback fun(repo_root: string)
function M.get_repo_root(callback)
    if not utils.get_filepath() then
        return
    end
    local command = utils.make_local_command("jj --ignore-working-copy root")

    utils.start_job(command, {
        on_stdout = function(data)
            callback(data[1])
        end,
    })
end

function M.load_blames(callback)
    local blames = {}

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    if #lines == 0 then
        return
    end

    local filepath = vim.api.nvim_buf_get_name(0)
    if filepath == "" then
        return
    end

    local buftype = vim.api.nvim_buf_get_option(0, "bt")
    if buftype ~= "" then
        return
    end

    local filetype = vim.api.nvim_buf_get_option(0, "ft")
    if vim.tbl_contains(vim.g.gitblame_ignored_filetypes, filetype) then
        return
    end

    if files_data_loading[filepath] then
        return
    end

    files_data_loading[filepath] = true

    local command = [[jj --ignore-working-copy --config ui.color=never file annotate --config templates.file_annotate='"separate(\"\n\", separate(\" \", commit.commit_id(), 99999, line_number, 1), \"author \" ++ commit.author().name(), \"author-time \" ++ commit.author().timestamp().format(\"%s\"), \"committer \" ++ commit.committer().name(), \"committer-time \" ++ commit.committer().timestamp().format(\"%s\"), \"summary \" ++ commit.description().first_line(), \"\t\" ++ content)++ \"\n\""' ]] .. vim.fn.shellescape(filepath)

    utils.start_job(command, {
        on_stdout = function(data)
            process_blame_output(blames, filepath, data)
            if callback then
                callback()
            end
        end,
        on_exit = function()
            files_data_loading[filepath] = nil
        end,
    })
end

---@param info BlameInfo
---@param template string
---@return string formatted_message
function M.format_blame_text(info, template)
    local text = template
    --utils.log(info)
    text = text:gsub("<author>", info.author)
    text = text:gsub("<committer>", info.committer)
    text = text:gsub("<committer%-date>", format_date(info.committer_date))
    text = text:gsub("<date>", format_date(info.date))

    local summary_escaped = info.summary and info.summary:gsub("%%", "%%%%") or ""
    if info.summary == "" then
        summary_escaped = "(empty)"
    end
    text = text:gsub("<summary>", utils.truncate_description(summary_escaped, vim.g.gitblame_max_commit_summary_length))

    text = text:gsub("<sha>", info.sha and string.sub(info.sha, 1, 7) or "")

    return text
end

---@param callback fun(current_author: string)
function M.find_current_author(callback)
    utils.start_job("jj --ignore-working-copy config get user.name", {
        ---@param data string[]
        on_stdout = function(data)
            current_author = data[1]
            if callback then
                callback(current_author)
            end
        end,
    })
end

---Returns SHA for the latest commit to the current branch.
---@param callback fun(sha: string)
function M.get_latest_sha(callback)
    utils.start_job("jj --ignore-working-copy log -T 'commit_id' --no-graph -r @-", {
        on_stdout = function(data)
            callback(data[1])
        end,
    })
end

return M
