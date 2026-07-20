#!/usr/bin/env Rscript

# Shared path bootstrap for workflow step scripts.
#
# Usage from a workflow step:
#   source("workflow/workflow_bootstrap.R")
#   set_workflow_root()

resolve_workflow_script_path <- function() {
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg) > 0) {
    return(normalizePath(sub("^--file=", "", file_arg[1]), winslash = "/", mustWork = FALSE))
  }

  if (!is.null(sys.frames()[[1]]$ofile)) {
    return(normalizePath(sys.frames()[[1]]$ofile, winslash = "/", mustWork = FALSE))
  }

  NA_character_
}

set_workflow_root <- function() {
  script_path <- resolve_workflow_script_path()
  if (!is.na(script_path)) {
    setwd(normalizePath(file.path(dirname(script_path), ".."), winslash = "/", mustWork = FALSE))
    return(invisible(getwd()))
  }

  # Fallback: if already at project root, keep current directory.
  if (file.exists("config.R") && dir.exists("workflow")) {
    return(invisible(getwd()))
  }

  stop("Unable to determine workflow project root. Run as `Rscript workflow/<step>.R` from the repository root.")
}
