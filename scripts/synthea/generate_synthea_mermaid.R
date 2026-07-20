#!/usr/bin/env Rscript

# Generate a self-contained HTML state-diagram viewer from a Synthea GMF module JSON.
# Each node label includes the state name, state type, and all SNOMED/LOINC/RxNorm codes.
# The output HTML file can be opened in any modern browser (requires internet for Mermaid CDN).
#
# Usage:
#   Rscript scripts/synthea/generate_synthea_mermaid.R <input_json> <output_html>

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2) {
  stop("Usage: Rscript scripts/synthea/generate_synthea_mermaid.R <input_json> <output_html>")
}

input_json  <- args[[1]]
output_html <- args[[2]]

if (!file.exists(input_json)) {
  stop(sprintf("Input module not found: %s", input_json))
}

if (!requireNamespace("jsonlite", quietly = TRUE)) {
  stop("Package 'jsonlite' is required. Install with: renv::install('jsonlite')")
}

module <- jsonlite::fromJSON(input_json, simplifyVector = FALSE)
states <- module$states
if (is.null(states) || length(states) == 0) {
  stop("No states found in module JSON.")
}

state_names <- names(states)
node_ids <- sprintf("n%03d", seq_along(state_names))
names(node_ids) <- state_names

escape_mermaid <- function(x) {
  x <- gsub('"', "'", x, fixed = TRUE)
  x <- gsub("\\[", "(", x)
  x <- gsub("\\]", ")", x)
  x <- gsub("\\n", " ", x)
  trimws(x)
}

# Build a rich node label including state type and all codes (for htmlLabels rendering).
make_rich_label <- function(state_name, state) {
  name_part <- escape_mermaid(gsub("_", " ", state_name, fixed = TRUE))
  type_part  <- if (!is.null(state$type)) paste0("[", state$type, "]") else ""

  code_parts <- character(0)
  if (!is.null(state$codes) && length(state$codes) > 0) {
    for (cd in state$codes) {
      sys  <- if (!is.null(cd$system))  cd$system  else ""
      code_val <- if (!is.null(cd$code))    cd$code    else ""
      disp <- if (!is.null(cd$display)) escape_mermaid(cd$display) else ""
      if (nzchar(sys) || nzchar(code_val)) {
        code_parts <- c(code_parts, paste0(sys, " ", code_val, ": ", disp))
      }
    }
  }
  if (!is.null(state$value_code)) {
    vc <- state$value_code
    sys  <- if (!is.null(vc$system))  vc$system  else ""
    code_val <- if (!is.null(vc$code))    vc$code    else ""
    disp <- if (!is.null(vc$display)) escape_mermaid(vc$display) else ""
    if (nzchar(sys) || nzchar(code_val)) {
      code_parts <- c(code_parts, paste0("val: ", sys, " ", code_val, ": ", disp))
    }
  }

  all_parts <- c(paste0("<b>", name_part, "</b>"), type_part)
  if (length(code_parts) > 0) all_parts <- c(all_parts, code_parts)
  paste(all_parts, collapse = "<br/>")
}

short_percent <- function(x) {
  pct <- 100 * as.numeric(x)
  txt <- sprintf("%.1f", pct)
  txt <- sub("\\.0$", "", txt)
  paste0(txt, "%")
}

node_lines_rich <- character(0)
edge_lines      <- character(0)

format_condition_label <- function(cond) {
  if (is.null(cond) || length(cond) == 0) {
    return("else")
  }

  parts <- character(0)
  if (!is.null(cond$condition_type)) {
    parts <- c(parts, cond$condition_type)
  }

  if (!is.null(cond$codes) && length(cond$codes) > 0) {
    first_code <- cond$codes[[1]]
    if (!is.null(first_code$display)) {
      parts <- c(parts, first_code$display)
    }
  }

  if (!is.null(cond$operator) && !is.null(cond$value)) {
    parts <- c(parts, paste(cond$operator, cond$value))
  }

  if (length(parts) == 0) {
    return("condition")
  }

  paste(parts, collapse = ": ")
}

for (state_name in state_names) {
  state <- states[[state_name]]
  node_id <- node_ids[[state_name]]

  label <- gsub("_", " ", state_name, fixed = TRUE)
  label <- escape_mermaid(label)
  node_lines_rich <- c(node_lines_rich, sprintf("  %s[\"%s\"]", node_id, make_rich_label(state_name, state)))

  if (!is.null(state$direct_transition)) {
    to_name <- state$direct_transition
    if (!is.null(node_ids[[to_name]])) {
      edge_lines <- c(edge_lines, sprintf("  %s --> %s", node_id, node_ids[[to_name]]))
    }
  }

  if (!is.null(state$distributed_transition) && length(state$distributed_transition) > 0) {
    for (tr in state$distributed_transition) {
      if (is.null(tr$transition) || is.null(node_ids[[tr$transition]])) {
        next
      }
      lbl <- ""
      if (!is.null(tr$distribution)) {
        lbl <- short_percent(tr$distribution)
      }
      if (nzchar(lbl)) {
        edge_lines <- c(edge_lines, sprintf("  %s -- %s --> %s", node_id, escape_mermaid(lbl), node_ids[[tr$transition]]))
      } else {
        edge_lines <- c(edge_lines, sprintf("  %s --> %s", node_id, node_ids[[tr$transition]]))
      }
    }
  }

  if (!is.null(state$conditional_transition) && length(state$conditional_transition) > 0) {
    for (tr in state$conditional_transition) {
      if (is.null(tr$transition) || is.null(node_ids[[tr$transition]])) {
        next
      }
      cond_label <- format_condition_label(tr$condition)
      edge_lines <- c(edge_lines, sprintf("  %s -- %s --> %s", node_id, escape_mermaid(cond_label), node_ids[[tr$transition]]))
    }
  }
}

mermaid_lines_rich <- c(
  "flowchart TD",
  node_lines_rich,
  "",
  edge_lines
)

out_dir <- dirname(output_html)
if (!dir.exists(out_dir)) {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
}

# Generate a self-contained HTML viewer (browser-openable, no VS Code required).
# Requires an internet connection to load Mermaid.js from CDN.
  esc_html <- function(x) {
    x <- gsub("&", "&amp;", x, fixed = TRUE)
    x <- gsub("<", "&lt;", x, fixed = TRUE)
    x <- gsub(">", "&gt;", x, fixed = TRUE)
    x
  }

  full_mermaid_text <- paste(c(
    "%%{init: {'theme': 'default', 'flowchart': {'useMaxWidth': true, 'htmlLabels': true}} }%%",
    mermaid_lines_rich
  ), collapse = "\n")

  html_lines <- c(
    "<!DOCTYPE html>",
    '<html lang="en">',
    "<head>",
    '  <meta charset="UTF-8">',
    '  <meta name="viewport" content="width=device-width, initial-scale=1.0">',
    "  <title>PAD/SSI Synthea Module Diagram</title>",
    '  <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>',
    "  <style>",
    "    body { font-family: sans-serif; margin: 2em; max-width: 1400px; background: #f5f5f5; color: #222; }",
    "    h1 { color: #1a1a2e; }",
    "    .diagram-box { background: white; border: 1px solid #ddd; border-radius: 6px; padding: 1.5em; overflow-x: auto; margin-top: 1em; }",
    "    footer { margin-top: 3em; font-size: 0.8em; color: #aaa; border-top: 1px solid #eee; padding-top: 1em; }",
    "  </style>",
    "</head>",
    "<body>",
    "  <h1>Synthea Study Module &mdash; State Diagram</h1>",
    "  <p>Generated from the study module JSON. Each node shows state name, type, and codes. Open in any modern browser.</p>",
    '  <div class="diagram-box">',
    '    <div class="mermaid">',
    esc_html(full_mermaid_text),
    "    </div>",
    "  </div>",
    "",
    "  <footer>",
    '    Rendered with <a href="https://mermaid.js.org">Mermaid.js</a> (CDN). Requires an internet connection.',
    "  </footer>",
    "  <script>mermaid.initialize({ startOnLoad: true });</script>",
    "</body>",
    "</html>"
  )

  writeLines(html_lines, con = output_html, useBytes = TRUE)
  cat(sprintf("Wrote HTML viewer: %s\n", output_html))
