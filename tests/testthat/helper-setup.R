# Compute an absolute path to the project root once.
# testthat 3 changes CWD to the test directory before each file;
# test files use .PROJ_ROOT to build absolute source() paths instead
# of relying on a relative working directory.
.PROJ_ROOT <- normalizePath(
  if (file.exists("R/connection.R")) getwd() else file.path(getwd(), "../..")
)
