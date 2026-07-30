-- Test init file for development
vim.opt.runtimepath:prepend(vim.fn.getcwd())

require("project-panel").setup({
  projects_dir = vim.fn.expand("~/projects"),
  width = 35,
  position = "left",
  auto_open = false,
  show_hidden = true,
})

vim.keymap.set("n", "<leader>pp", "<cmd>ProjectPanelToggle<cr>", { desc = "Toggle Project Panel" })
vim.keymap.set("n", "<leader>po", "<cmd>ProjectPanel<cr>", { desc = "Open Project Panel" })

print("project-panel.nvim loaded. Use <leader>pp to toggle panel.")
