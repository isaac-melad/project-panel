if exists("g:loaded_project_panel")
  finish
endif
let g:loaded_project_panel = 1

lua << END
require("project-panel").setup()
END
