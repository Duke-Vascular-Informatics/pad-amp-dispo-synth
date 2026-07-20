library(testthat)

# Ensure working directory is project root so source() paths in test files work.
proj_root <- normalizePath(if (file.exists("R/connection.R")) "." else "../..")
withr::with_dir(proj_root, test_dir("tests/testthat"))
