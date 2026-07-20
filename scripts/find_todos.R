#!/usr/bin/env Rscript
# =============================================================================
# scripts/find_todos.R
#
# Lists every TODO placeholder that still needs to be filled in before running
# Step 8.  Works on Windows, macOS, and Linux (no shell grep required).
#
# Usage (from project root):
#   Rscript scripts/find_todos.R
#   Rscript scripts/find_todos.R --files path1 path2 ...
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) > 0 && identical(args[1], "--files")) {
  targets <- unique(args[-1])
} else {
  targets <- c(
    "study_params.yaml",
    list.files("covariates", pattern = "\\.csv$", full.names = TRUE, recursive = TRUE),
    list.files("workflow", pattern = "^07|^08", full.names = TRUE)
  )
}

targets <- targets[file.exists(targets)]

if (length(targets) == 0L) {
  message("No matching files to scan for TODO placeholders.")
  quit(status = 0)
}

found <- 0L
for (path in targets) {
  lines <- tryCatch(readLines(path, warn = FALSE), error = function(e) character(0))
  hits  <- grep("TODO \\[", lines)
  for (i in hits) {
    cat(sprintf("%s:%d: %s\n", path, i, trimws(lines[i])))
    found <- found + 1L
  }
}

if (found == 0L) {
  message("No TODO placeholders found — ready to run Step 8.")
} else {
  message(sprintf("\n%d TODO placeholder(s) remaining.", found))
}
