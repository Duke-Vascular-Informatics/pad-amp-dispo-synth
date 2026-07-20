#!/usr/bin/env Rscript
# =============================================================================
# scripts/create_support_bundle.R
#
# Creates a support bundle for analyst troubleshooting. The bundle is safe to
# share internally and includes redacted config plus diagnostics.
# =============================================================================

args_full <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", args_full, value = TRUE)
if (length(file_arg) > 0) {
  script_dir <- dirname(normalizePath(sub("^--file=", "", file_arg[1]), winslash = "/"))
  proj_root <- dirname(script_dir)
} else {
  proj_root <- getwd()
}
setwd(proj_root)

run_capture <- function(cmd, args = character(0)) {
  out <- tryCatch(
    suppressWarnings(system2(cmd, args = args, stdout = TRUE, stderr = TRUE)),
    error = function(e) sprintf("ERROR running %s: %s", cmd, conditionMessage(e))
  )
  paste(out, collapse = "\n")
}

redact_lines <- function(lines) {
  # Redact common secret keys in YAML/env style lines.
  secret_key <- "(?i)^(\\s*)([^#]*?(password|secret|token|api[_-]?key)[^:]*):\\s*(.*)$"
  secret_env <- "(?i)^(\\s*)([^#]*?(password|secret|token|api[_-]?key)[^=]*)=(.*)$"
  lines <- gsub(secret_key, "\\1\\2: [REDACTED]", lines, perl = TRUE)
  lines <- gsub(secret_env, "\\1\\2=[REDACTED]", lines, perl = TRUE)
  lines
}

copy_recent_logs <- function(dest_dir, max_files = 20L) {
  candidates <- character(0)
  for (root in c("logs", "output")) {
    if (!dir.exists(root)) next
    files <- list.files(root, recursive = TRUE, full.names = TRUE, all.files = FALSE)
    files <- files[!grepl("^output/support(/|$)", files)]
    files <- files[file.exists(files)]
    files <- files[!dir.exists(files)]
    files <- files[grepl("\\.(log|txt|out|err)$", files, ignore.case = TRUE)]
    candidates <- c(candidates, files)
  }

  if (length(candidates) == 0) return(invisible(NULL))

  info <- file.info(candidates)
  ord <- order(info$mtime, decreasing = TRUE, na.last = NA)
  candidates <- candidates[ord]
  candidates <- head(candidates, max_files)

  log_dir <- file.path(dest_dir, "logs")
  dir.create(log_dir, recursive = TRUE, showWarnings = FALSE)

  for (f in candidates) {
    out_name <- gsub("[/\\\\]", "__", f)
    ok <- file.copy(f, file.path(log_dir, out_name), overwrite = TRUE)
    if (!ok) next
  }
}

ts <- format(Sys.time(), "%Y%m%d_%H%M%S")
bundle_dir <- file.path("output", "support", paste0("support_bundle_", ts))
dir.create(bundle_dir, recursive = TRUE, showWarnings = FALSE)

writeLines(c(
  sprintf("Created: %s", as.character(Sys.time())),
  sprintf("Working directory: %s", normalizePath(getwd(), winslash = "/")),
  sprintf("R version: %s", R.version.string)
), file.path(bundle_dir, "bundle_info.txt"))

writeLines(run_capture("git", c("rev-parse", "--abbrev-ref", "HEAD")),
           file.path(bundle_dir, "git_branch.txt"))
writeLines(run_capture("git", c("status", "--short")),
           file.path(bundle_dir, "git_status_short.txt"))
writeLines(run_capture("git", c("log", "-n", "10", "--oneline")),
           file.path(bundle_dir, "git_log_last10.txt"))

if (file.exists("study_params.yaml")) {
  lines <- readLines("study_params.yaml", warn = FALSE)
  writeLines(redact_lines(lines), file.path(bundle_dir, "study_params.redacted.yaml"))
}

if (file.exists("scripts/check_setup.R")) {
  check_out <- run_capture("Rscript", c("scripts/check_setup.R"))
  writeLines(check_out, file.path(bundle_dir, "check_setup.txt"))
}

copy_recent_logs(bundle_dir)

archive_path <- file.path(proj_root, "output", "support", paste0("support_bundle_", ts, ".tar.gz"))
old_wd <- getwd()
setwd(dirname(bundle_dir))
utils::tar(
  tarfile = archive_path,
  files = basename(bundle_dir),
  compression = "gzip"
)
setwd(old_wd)

cat("Support bundle created:\n")
cat("  Folder: ", normalizePath(bundle_dir, winslash = "/"), "\n", sep = "")
cat("  Archive:", normalizePath(archive_path, winslash = "/"), "\n", sep = "")
