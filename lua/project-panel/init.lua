local M = {}

local has_devicons, devicons = pcall(require, "nvim-web-devicons")
local uv = vim.uv or vim.loop

local config = {
  projects_dir = vim.fn.expand("~/projects"), -- for backwards compatibility
  width = 30,
  position = "left",
  auto_open = false,
  show_hidden = false,
  use_nerd_fonts = has_devicons,
  icons = {
    folder_closed = "📁",
    folder_open = "📂",
    default_file = "📄",
    arrow_closed = "▸",
    arrow_open = "▾",
  }
}

local state = {
  win_id = nil,
  buf_id = nil,
  root = nil,
  rendered_nodes = {},
}

local header_offset = 2

-- Helper for backward/forward compatible option getting/setting
local function set_buf_opt(buf, opt, val)
  if vim.api.nvim_set_option_value then
    vim.api.nvim_set_option_value(opt, val, { buf = buf })
  else
    vim.api.nvim_buf_set_option(buf, opt, val)
  end
end

local function set_win_opt(win, opt, val)
  if vim.api.nvim_set_option_value then
    vim.api.nvim_set_option_value(opt, val, { win = win })
  else
    vim.api.nvim_win_set_option(win, opt, val)
  end
end

local function get_buf_opt(buf, opt)
  if vim.api.nvim_get_option_value then
    return vim.api.nvim_get_option_value(opt, { buf = buf })
  else
    return vim.api.nvim_buf_get_option(buf, opt)
  end
end

-- Node representation for the directory tree
local Node = {}
Node.__index = Node

function Node.new(path, type, depth, parent)
  local name = vim.fn.fnamemodify(path, ":t")
  if name == "" or not name then
    name = path
  end
  return setmetatable({
    path = path,
    name = name,
    type = type,
    depth = depth or 0,
    parent = parent,
    open = false,
    children = nil,
  }, Node)
end

function Node:load_children(show_hidden)
  if self.type ~= "directory" then return end
  self.children = {}
  
  local handle = uv.fs_scandir(self.path)
  if not handle then return end
  
  while true do
    local name, type = uv.fs_scandir_next(handle)
    if not name then break end
    if show_hidden or not name:match("^%.") then
      local child_path = self.path .. "/" .. name
      child_path = child_path:gsub("//+", "/")
      
      -- Resolve type if it is a link or undefined
      if not type or type == "link" then
        local stat = uv.fs_stat(child_path)
        if stat then
          type = stat.type
        end
      end
      
      table.insert(self.children, Node.new(child_path, type or "file", self.depth + 1, self))
    end
  end
  
  -- Sort directories first, then files alphabetically
  table.sort(self.children, function(a, b)
    if a.type ~= b.type then
      return a.type == "directory"
    end
    return a.name:lower() < b.name:lower()
  end)
end

local function initialize_root(dir_path)
  local path = dir_path or vim.fn.getcwd()
  path = path:gsub("/$", "")
  state.root = Node.new(path, "directory", 0, nil)
  state.root.open = true
  state.root:load_children(config.show_hidden)
end

local function build_render_list(node, list)
  table.insert(list, node)
  if node.type == "directory" and node.open and node.children then
    for _, child in ipairs(node.children) do
      build_render_list(child, list)
    end
  end
end

local function get_open_paths(node, paths)
  paths = paths or {}
  if node and node.type == "directory" and node.open then
    paths[node.path] = true
    if node.children then
      for _, child in ipairs(node.children) do
        get_open_paths(child, paths)
      end
    end
  end
  return paths
end

local function restore_open_paths(node, paths)
  if node and node.type == "directory" then
    if paths[node.path] then
      node.open = true
      node:load_children(config.show_hidden)
      if node.children then
        for _, child in ipairs(node.children) do
          restore_open_paths(child, paths)
        end
      end
    end
  end
end

function M.reload_tree()
  if not state.root then return end
  local open_paths = get_open_paths(state.root)
  state.root:load_children(config.show_hidden)
  restore_open_paths(state.root, open_paths)
end

local function get_node_under_cursor()
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then return nil end
  local cursor = vim.api.nvim_win_get_cursor(state.win_id)
  local line = cursor[1]
  local index = line - header_offset
  if index >= 1 and index <= #state.rendered_nodes then
    return state.rendered_nodes[index]
  end
  return nil
end

local function render_tree()
  if not state.buf_id or not vim.api.nvim_buf_is_valid(state.buf_id) then return end

  state.rendered_nodes = {}
  if state.root and state.root.children then
    for _, child in ipairs(state.root.children) do
      build_render_list(child, state.rendered_nodes)
    end
  end

  local lines = {}
  local root_name = vim.fn.fnamemodify(state.root.path, ":t")
  if root_name == "" then root_name = state.root.path end
  
  -- Header
  table.insert(lines, "  PROJECT: " .. root_name)
  table.insert(lines, "  " .. string.rep("─", config.width - 4))

  local highlights = {}

  for idx, node in ipairs(state.rendered_nodes) do
    local line_num = idx + header_offset - 1
    
    local indent = ""
    for d = 2, node.depth do
      indent = indent .. "│ "
    end
    
    local indicator = ""
    if node.type == "directory" then
      indicator = node.open and (config.icons.arrow_open .. " ") or (config.icons.arrow_closed .. " ")
    else
      indicator = "  "
    end
    
    local icon = config.icons.default_file
    local icon_hl = "ProjectPanelFileIcon"
    
    if node.type == "directory" then
      icon = node.open and config.icons.folder_open or config.icons.folder_closed
      icon_hl = "ProjectPanelFolderIcon"
    else
      if has_devicons then
        local ext = vim.fn.fnamemodify(node.name, ":e")
        local dev_icon, dev_hl = devicons.get_icon(node.name, ext, { default = true })
        if dev_icon then
          icon = dev_icon
          icon_hl = dev_hl
        end
      end
    end
    
    local prefix = " " .. indent .. indicator
    local icon_start = string.len(prefix)
    local icon_end = icon_start + string.len(icon)
    
    local line_content = prefix .. icon .. " " .. node.name
    table.insert(lines, line_content)
    
    -- Highlight guide lines
    local guide_offset = 1
    for d = 2, node.depth do
      table.insert(highlights, { group = "ProjectPanelGuide", line = line_num, start = guide_offset, finish = guide_offset + string.len("│") })
      guide_offset = guide_offset + string.len("│ ")
    end
    
    -- Highlight icon
    table.insert(highlights, { group = icon_hl, line = line_num, start = icon_start, finish = icon_end })
    
    -- Highlight name
    local text_start = icon_end + 1
    local text_end = string.len(line_content)
    local text_hl = node.type == "directory" and "ProjectPanelDirectory" or "ProjectPanelFile"
    table.insert(highlights, { group = text_hl, line = line_num, start = text_start, finish = text_end })
  end

  table.insert(lines, "")
  table.insert(lines, "  Press ? for help")

  set_buf_opt(state.buf_id, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.buf_id, 0, -1, false, lines)
  set_buf_opt(state.buf_id, "modifiable", false)

  -- Apply highlights
  vim.api.nvim_buf_add_highlight(state.buf_id, -1, "ProjectPanelTitle", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(state.buf_id, -1, "ProjectPanelBorder", 1, 0, -1)
  vim.api.nvim_buf_add_highlight(state.buf_id, -1, "Comment", #lines - 1, 0, -1)
  
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(state.buf_id, -1, hl.group, hl.line, hl.start, hl.finish)
  end
end

local function get_target_window()
  local current_tab = vim.api.nvim_get_current_tabpage()
  local wins = vim.api.nvim_tabpage_list_wins(current_tab)
  
  -- Search for editing window
  for _, win in ipairs(wins) do
    if win ~= state.win_id and vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local buftype = get_buf_opt(buf, "buftype")
      if buftype == "" then
        return win
      end
    end
  end
  
  -- Fallback to any valid window that is not the sidebar
  for _, win in ipairs(wins) do
    if win ~= state.win_id and vim.api.nvim_win_is_valid(win) then
      return win
    end
  end
  
  return nil
end

function M.open_file(file_path)
  local win = get_target_window()
  if win then
    vim.api.nvim_set_current_win(win)
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(file_path))
  else
    vim.cmd("wincmd l")
    local cur_win = vim.api.nvim_get_current_win()
    if cur_win == state.win_id then
      vim.cmd("vertical split")
      local new_win = vim.api.nvim_get_current_win()
      vim.api.nvim_set_current_win(new_win)
    end
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(file_path))
  end
end

function M.handle_click()
  local node = get_node_under_cursor()
  if not node then return end

  if node.type == "directory" then
    node.open = not node.open
    if node.open and not node.children then
      node:load_children(config.show_hidden)
    end
    local cursor = vim.api.nvim_win_get_cursor(state.win_id)
    render_tree()
    local max_line = vim.api.nvim_buf_line_count(state.buf_id)
    local target_line = math.min(cursor[1], max_line)
    vim.api.nvim_win_set_cursor(state.win_id, { target_line, cursor[2] })
  else
    M.open_file(node.path)
  end
end

local function get_target_dir_for_creation()
  local node = get_node_under_cursor()
  if not node then
    return state.root.path
  end
  if node.type == "directory" then
    return node.path
  else
    return vim.fn.fnamemodify(node.path, ":h")
  end
end

function M.create_file()
  local target_dir = get_target_dir_for_creation()
  vim.ui.input({
    prompt = "Create file/folder (end with / for folder): ",
    default = target_dir .. "/",
  }, function(input)
    if not input or input == "" or input == target_dir .. "/" then return end
    
    local is_dir = input:match("/$") ~= nil
    local absolute_path = input
    
    if is_dir then
      local ok, err = pcall(vim.fn.mkdir, absolute_path, "p")
      if ok then
        vim.notify("Created directory: " .. absolute_path, vim.log.levels.INFO)
      else
        vim.notify("Error creating directory: " .. tostring(err), vim.log.levels.ERROR)
      end
    else
      local parent_dir = vim.fn.fnamemodify(absolute_path, ":h")
      vim.fn.mkdir(parent_dir, "p")
      
      local file = io.open(absolute_path, "w")
      if file then
        file:close()
        vim.notify("Created file: " .. absolute_path, vim.log.levels.INFO)
      else
        vim.notify("Error creating file: " .. absolute_path, vim.log.levels.ERROR)
      end
    end
    
    M.reload_tree()
    render_tree()
  end)
end

function M.rename_file()
  local node = get_node_under_cursor()
  if not node then return end
  
  local old_path = node.path
  local parent_dir = vim.fn.fnamemodify(old_path, ":h")
  local old_name = node.name
  
  vim.ui.input({
    prompt = "Rename to: ",
    default = old_name,
  }, function(new_name)
    if not new_name or new_name == "" or new_name == old_name then return end
    
    local new_path = parent_dir .. "/" .. new_name
    new_path = new_path:gsub("//+", "/")
    
    local result = vim.fn.rename(old_path, new_path)
    if result == 0 then
      vim.notify("Renamed: " .. old_name .. " -> " .. new_name, vim.log.levels.INFO)
      M.reload_tree()
      render_tree()
    else
      vim.notify("Error renaming " .. old_name, vim.log.levels.ERROR)
    end
  end)
end

function M.delete_file()
  local node = get_node_under_cursor()
  if not node then return end
  
  local path = node.path
  local name = node.name
  local msg = "Delete " .. (node.type == "directory" and "directory" or "file") .. ": " .. name .. "?"
  
  vim.ui.select({ "Yes", "No" }, {
    prompt = msg,
  }, function(choice)
    if choice == "Yes" then
      local result
      if node.type == "directory" then
        result = vim.fn.delete(path, "rf")
      else
        result = vim.fn.delete(path)
      end
      
      if result == 0 then
        vim.notify("Deleted " .. name, vim.log.levels.INFO)
        M.reload_tree()
        render_tree()
      else
        vim.notify("Error deleting " .. name, vim.log.levels.ERROR)
      end
    end
  end)
end

function M.move_file()
  local node = get_node_under_cursor()
  if not node then return end
  
  local old_path = node.path
  local name = node.name
  
  vim.ui.input({
    prompt = "Move/Cut-Paste to: ",
    default = old_path,
  }, function(new_path)
    if not new_path or new_path == "" or new_path == old_path then return end
    
    local new_parent = vim.fn.fnamemodify(new_path, ":h")
    if vim.fn.isdirectory(new_parent) == 0 then
      vim.fn.mkdir(new_parent, "p")
    end
    
    local result = vim.fn.rename(old_path, new_path)
    if result == 0 then
      vim.notify("Moved " .. name .. " to " .. new_path, vim.log.levels.INFO)
      M.reload_tree()
      render_tree()
    else
      vim.notify("Error moving " .. name, vim.log.levels.ERROR)
    end
  end)
end

function M.go_up()
  local parent_path = vim.fn.fnamemodify(state.root.path, ":h")
  if parent_path == state.root.path then
    vim.notify("Already at root directory", vim.log.levels.WARN)
    return
  end
  initialize_root(parent_path)
  render_tree()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    vim.api.nvim_win_set_cursor(state.win_id, { header_offset + 1, 0 })
  end
end

function M.set_root_to_selected()
  local node = get_node_under_cursor()
  if not node then return end
  if node.type == "directory" then
    initialize_root(node.path)
    render_tree()
    if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
      vim.api.nvim_win_set_cursor(state.win_id, { header_offset + 1, 0 })
    end
  end
end

function M.show_help()
  local help_text = {
    "Project Panel Keymaps:",
    "───────────────────────────────────",
    "  <CR> / o   : Open file / Toggle folder",
    "  a          : Create file or folder",
    "  r          : Rename selected item",
    "  d          : Delete selected item",
    "  m          : Move selected item",
    "  - / u      : Go up to parent directory",
    "  C          : Set selected folder as root",
    "  R          : Refresh file explorer",
    "  q / <Esc>  : Close Project Panel",
    "  ?          : Close this help menu",
  }
  
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, help_text)
  set_buf_opt(buf, "modifiable", false)
  set_buf_opt(buf, "buftype", "nofile")
  
  local width = 45
  local height = #help_text
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Project Panel Help ",
    title_pos = "center",
  })
  
  local close_help = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "<Esc>", close_help, { buffer = buf, silent = true })
  vim.keymap.set("n", "q", close_help, { buffer = buf, silent = true })
  vim.keymap.set("n", "?", close_help, { buffer = buf, silent = true })
  vim.keymap.set("n", "<CR>", close_help, { buffer = buf, silent = true })
end

local function setup_highlights()
  local def_hls = {
    ProjectPanelTitle = { link = "Title" },
    ProjectPanelBorder = { link = "Comment" },
    ProjectPanelGuide = { link = "Comment" },
    ProjectPanelDirectory = { link = "Directory" },
    ProjectPanelFile = { link = "Normal" },
    ProjectPanelFolderIcon = { link = "Directory" },
    ProjectPanelFileIcon = { link = "Normal" },
  }
  for hl_group, hl_val in pairs(def_hls) do
    vim.api.nvim_set_hl(0, hl_group, vim.tbl_extend("keep", hl_val, { default = true }))
  end
end

local function create_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  set_buf_opt(buf, "buftype", "nofile")
  set_buf_opt(buf, "bufhidden", "wipe")
  set_buf_opt(buf, "swapfile", false)
  set_buf_opt(buf, "filetype", "project-panel")
  
  local opts = { noremap = true, silent = true, buffer = buf }
  vim.keymap.set("n", "q", M.close, opts)
  vim.keymap.set("n", "<Esc>", M.close, opts)
  
  vim.keymap.set("n", "<CR>", M.handle_click, opts)
  vim.keymap.set("n", "o", M.handle_click, opts)
  
  vim.keymap.set("n", "a", M.create_file, opts)
  vim.keymap.set("n", "r", M.rename_file, opts)
  vim.keymap.set("n", "d", M.delete_file, opts)
  vim.keymap.set("n", "m", M.move_file, opts)
  vim.keymap.set("n", "R", M.refresh, opts)
  vim.keymap.set("n", "-", M.go_up, opts)
  vim.keymap.set("n", "u", M.go_up, opts)
  vim.keymap.set("n", "C", M.set_root_to_selected, opts)
  vim.keymap.set("n", "?", M.show_help, opts)
  
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      state.win_id = nil
      state.buf_id = nil
    end,
  })
  
  return buf
end

local function open_window()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    vim.api.nvim_set_current_win(state.win_id)
    return
  end
  
  if not state.buf_id or not vim.api.nvim_buf_is_valid(state.buf_id) then
    state.buf_id = create_buffer()
  end
  
  local position = config.position == "right" and "botright" or "topleft"
  vim.cmd(position .. " vertical " .. config.width .. "split")
  
  state.win_id = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win_id, state.buf_id)
  
  set_win_opt(state.win_id, "number", false)
  set_win_opt(state.win_id, "relativenumber", false)
  set_win_opt(state.win_id, "signcolumn", "no")
  set_win_opt(state.win_id, "winfixwidth", true)
  set_win_opt(state.win_id, "wrap", false)
  set_win_opt(state.win_id, "cursorline", true)
  
  M.refresh()
end

local function setup_autocmds()
  local group = vim.api.nvim_create_augroup("ProjectPanelAutoClose", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = "*",
    callback = function()
      if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
        local wins = vim.api.nvim_tabpage_list_wins(0)
        local normal_win_count = 0
        for _, win in ipairs(wins) do
          local win_cfg = vim.api.nvim_win_get_config(win)
          if win_cfg.relative == "" then
            normal_win_count = normal_win_count + 1
          end
        end
        if normal_win_count == 1 and vim.api.nvim_get_current_win() == state.win_id then
          vim.cmd("quit")
        end
      end
    end,
  })
  
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    pattern = "*",
    callback = function()
      if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
        initialize_root(vim.v.event.cwd or vim.fn.getcwd())
        render_tree()
      end
    end,
  })
end

local function initialize_icons()
  if config.use_nerd_fonts then
    config.icons = vim.tbl_extend("force", {
      folder_closed = "",
      folder_open = "",
      default_file = "󰈔",
      arrow_closed = "",
      arrow_open = "",
    }, config.icons or {})
  end
end

function M.check_config()
  local report = {
    "Project Panel Configuration & Conflict Checker",
    "==================================================",
    "",
  }
  
  -- 1. Check Devicons
  table.insert(report, "1. Devicons Status:")
  if has_devicons then
    table.insert(report, "   ✔ nvim-web-devicons is installed and loaded.")
  else
    table.insert(report, "   ⚠ nvim-web-devicons is not installed. Falling back to default emojis.")
  end
  table.insert(report, "")
  
  -- 2. Check Other File Explorers
  table.insert(report, "2. Potential File Explorer Conflicts:")
  local conflicting_plugins = {
    ["nvim-tree/nvim-tree.lua"] = "nvim-tree",
    ["nvim-neo-tree/neo-tree.nvim"] = "neo-tree",
    ["stevearc/oil.nvim"] = "oil",
  }
  local found_explorers = false
  local has_lazy, lazy_config = pcall(require, "lazy.core.config")
  if has_lazy and lazy_config.plugins then
    for pkg, name in pairs(conflicting_plugins) do
      if lazy_config.plugins[pkg] then
        table.insert(report, "   ⚠ Found competing explorer plugin: " .. name .. " (" .. pkg .. ")")
        found_explorers = true
      end
    end
  end
  if not found_explorers then
    table.insert(report, "   ✔ No other major file explorer plugins detected in lazy.nvim config.")
  end
  table.insert(report, "")
  
  -- 3. Check Keymap Conflicts
  table.insert(report, "3. Keymap Diagnostics:")
  local keymaps = vim.api.nvim_get_keymap("n")
  local our_keys = {
    ["<leader>pe"] = "Toggle Project Panel",
    ["<leader>po"] = "Open Project Panel",
    ["<leader>pp"] = "Toggle Project Panel",
  }
  local map_leader = vim.g.mapleader or "\\"
  
  local found_key_conflict = false
  for _, map in ipairs(keymaps) do
    local lhs = map.lhs
    local clean_lhs = lhs:gsub("<[lL]eader>", map_leader)
    
    for key, desc in pairs(our_keys) do
      local clean_key = key:gsub("<[lL]eader>", map_leader)
      if clean_lhs == clean_key then
        local rhs_str = ""
        if type(map.rhs) == "string" then
          rhs_str = map.rhs
        elseif type(map.callback) == "function" then
          rhs_str = tostring(map.callback)
        end
        
        if not rhs_str:match("project%-panel") and not (map.desc and map.desc:match("Project Panel")) then
          table.insert(report, string.format("   ⚠ Key '%s' is also mapped by another plugin/config: %s (Desc: %s)", lhs, rhs_str, map.desc or "none"))
          found_key_conflict = true
        end
      end
    end
  end
  if not found_key_conflict then
    table.insert(report, "   ✔ No keymap conflicts detected for Project Panel keys.")
  end
  table.insert(report, "")
  
  -- 4. Check Command Conflicts
  table.insert(report, "4. Command Diagnostics:")
  local commands = vim.api.nvim_get_commands({})
  local our_cmds = { "ProjectPanel", "ProjectPanelClose", "ProjectPanelToggle", "ProjectPanelRefresh" }
  local found_cmd_conflict = false
  for _, cmd_name in ipairs(our_cmds) do
    if commands[cmd_name] then
      local cmd_info = commands[cmd_name]
      local desc = cmd_info.desc or ""
      local definition = cmd_info.definition or ""
      if not desc:match("Project Panel") and not definition:match("ProjectPanel") then
        table.insert(report, "   ⚠ Command :" .. cmd_name .. " is defined by another source (Desc: " .. desc .. ")")
        found_cmd_conflict = true
      end
    end
  end
  if not found_cmd_conflict then
    table.insert(report, "   ✔ All Project Panel user commands are successfully registered.")
  end
  table.insert(report, "")
  table.insert(report, "==================================================")
  table.insert(report, "Press q or <Esc> to close this report.")
  
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, report)
  set_buf_opt(buf, "modifiable", false)
  set_buf_opt(buf, "buftype", "nofile")
  
  local width = 65
  local height = math.min(#report, vim.o.lines - 6)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Project Panel Diagnostics ",
    title_pos = "center",
  })
  
  local close_report = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "<Esc>", close_report, { buffer = buf, silent = true })
  vim.keymap.set("n", "q", close_report, { buffer = buf, silent = true })
end

function M.setup(user_config)
  config = vim.tbl_deep_extend("force", config, user_config or {})
  
  initialize_icons()
  setup_highlights()
  setup_autocmds()
  
  if config.auto_open then
    vim.defer_fn(function() M.open() end, 100)
  end
  
  vim.api.nvim_create_user_command("ProjectPanel", function() M.open() end, {})
  vim.api.nvim_create_user_command("ProjectPanelClose", function() M.close() end, {})
  vim.api.nvim_create_user_command("ProjectPanelToggle", function() M.toggle() end, {})
  vim.api.nvim_create_user_command("ProjectPanelRefresh", function() M.refresh() end, {})
  vim.api.nvim_create_user_command("ProjectPanelCheck", function() M.check_config() end, {})
end

function M.open(dir_path)
  if not state.root or dir_path then
    initialize_root(dir_path)
  end
  open_window()
end

function M.close()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    vim.api.nvim_win_close(state.win_id, true)
    state.win_id = nil
  end
end

function M.toggle()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    M.close()
  else
    M.open()
  end
end

function M.refresh()
  if not state.root then
    initialize_root()
  end
  M.reload_tree()
  render_tree()
end

return M
