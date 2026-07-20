source("renv/activate.R")

# Load .env if present — institution-specific settings (never committed)
local({
  env_file <- file.path(getwd(), ".env")
  if (file.exists(env_file)) {
    lines <- readLines(env_file, warn = FALSE)
    lines <- lines[!grepl("^\\s*#", lines) & nchar(trimws(lines)) > 0]
    for (line in lines) {
      eq <- regexpr("=", line, fixed = TRUE)
      if (eq < 2L) next
      key <- trimws(substr(line, 1L, eq - 1L))
      val <- trimws(substr(line, eq + 1L, nchar(line)))
      val <- gsub('^["\']|["\']$', "", val)  # strip optional surrounding quotes
      # setNames() lives in the stats package, not base -- at this point in
      # .Rprofile's startup sequence stats may not be attached yet in some R
      # builds, causing "could not find function setNames". `names<-` is a
      # base primitive, so build the named list without setNames().
      args <- list(val)
      names(args) <- key
      do.call(Sys.setenv, args)
    }
  }
})

# CRAN mirror — reads CRAN_MIRROR from .env / environment; falls back to cloud.r-project.org
options(repos = c(CRAN = Sys.getenv("CRAN_MIRROR", unset = "https://cloud.r-project.org")))
