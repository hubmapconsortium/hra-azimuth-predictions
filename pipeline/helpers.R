#' Converts gene names of query to match type/species of reference names (human
#' or mouse).
#'
#' @param object Object to convert, must contain only RNA counts matrix
#' @param reference.names Gene names of reference
#' @param homolog.table Location of file (or URL) containing table with
#' human/mouse homologies
#' @return query object with converted feature names, likely subsetted
#'
#' @importFrom stringr str_match
#' @importFrom shiny isRunning
#'
#' @export
#'
ConvertGeneNames <- function(object, reference.names, homolog.table) {
  uri <- httr::build_url(url = httr::parse_url(url = homolog.table))
  if (grepl(pattern = '^://', x = uri)) {
    if (!file.exists(homolog.table)) {
      stop("Homolog file doesn't exist at path provided: ", homolog.table)
    }
  } else {
    if (!Online(url = homolog.table)) {
      stop("Cannot find the homolog table at the URL given: ", homolog.table)
    }
    homolog.table <- url(description = homolog.table)
    on.exit(expr = {
      close(con = homolog.table)
    })
  }
  linked <- readRDS(file = homolog.table)
  query.names <- rownames(x = object)
  # remove version numbers
  ensembl.id <- '(?:ENSG|ENSMUS)'
  capture.nonversion <- paste0('(', ensembl.id, '.*)\\.(?:.*)')
  pattern <- paste0('(?:', capture.nonversion,')|(.*)')
  query.names <- Filter(
    f = function(x) !is.na(x = x),
    x = as.vector(x = t(x = str_match(string = query.names, pattern = pattern)[, 2:3]))
  )
  # determine idtype and species of query
  # 5000 because sometimes ensembl IDs are mixed with regular gene names
  query.names.sub = sample(
    x = query.names,
    size = min(length(x = query.names), 5000)
  )
  idtype <- names(x = which.max(x = apply(
    X = linked,
    MARGIN = 2,
    FUN = function(col) {
      length(x = intersect(x = col, y = query.names.sub))
    }
  )))
  species <- ifelse(test = length(x = grep(pattern = '\\.mouse', x = idtype)) > 0, 'mouse', 'human')
  idtype <- gsub(pattern = '\\.mouse|\\.human', replacement = '', x = idtype)
  message('detected inputs from ', toupper(x = species), ' with id type ', idtype)
  totalid <- paste0(idtype, '.', species)

  # determine idtype and species of ref
  reference.names.sub <- sample(x = reference.names, size = min(length(x = reference.names), 5000))
  idtype.ref <- names(x = which.max(x = apply(
    X = linked,
    MARGIN = 2,
    FUN = function(col) {
      length(x = intersect(x = col, y = reference.names))
    }
  )))
  species.ref <- ifelse(test = length(x = grep(pattern = '\\.mouse', x = idtype.ref)) > 0, 'mouse', 'human')
  idtype.ref <- gsub(pattern = '\\.mouse|\\.human', replacement = '', x = idtype.ref)
  message('reference rownames detected ', toupper(x = species.ref),' with id type ', idtype.ref)
  totalid.ref <- paste0(idtype.ref, '.', species.ref)

  if (totalid == totalid.ref) {
    return(object)
  } else {
    display.names <- setNames(
      c('ENSEMBL gene', 'ENSEMBL transcript', 'gene name', 'transcript name'),
      nm = c('Gene.stable.ID', 'Transcript.stable.ID','Gene.name','Transcript.name')
    )
    if (isRunning()) {
      showNotification(
        paste0(
          "Converted ",species," ",display.names[idtype]," IDs to ",
          species.ref," ",display.names[idtype.ref]," IDs"
        ),
        duration = 3,
        type = 'warning',
        closeButton = TRUE,
        id = 'no-progress-notification'
      )
    }
    # set up table indexed by query ids (totalid)
    linked.unique <- linked[!duplicated(x = linked[[totalid]]), ]
    new.indices <- which(query.names %in% linked.unique[[totalid]])
    message("Found ", length(x = new.indices), " out of ",
            length(x = query.names), " total inputs in conversion table")
    query.names <- query.names[new.indices]
    rownames(x = linked.unique) <- linked.unique[[totalid]]
    linked.unique <- linked.unique[query.names, ]
    # get converted totalid.ref
    new.names <- linked.unique[, totalid.ref]
    # remove duplicates
    notdup <- !duplicated(x = new.names)
    new.indices <- new.indices[notdup]
    new.names <- new.names[notdup]
    # subset/rename object accordingly
    counts <- GetAssayData(object = object[["RNA"]], slot = "counts")[rownames(x = object)[new.indices], ]
    rownames(x = counts) <- new.names
    object <- CreateSeuratObject(
      counts = counts,
      meta.data = object[[]]
    )
    return(object)
  }
}

#' Load file input into a \code{Seurat} object
#'
#' Take a file and load it into a \code{\link[Seurat]{Seurat}} object. Supports
#' a variety of file types and always returns a \code{Seurat} object
#'
#' @details \code{LoadFileInput} supports several file types to be read in as
#' \code{Seurat} objects. File type is determined by extension, matched in a
#' case-insensitive manner See sections below for details about supported
#' filtypes, required extension, and specifics for how data is loaded
#'
#' @param path Path to input data
#'
#' @return A \code{\link[Seurat]{Seurat}} object
#'
#' @importFrom tools file_ext
#' @importFrom SeuratDisk Connect
#' @importFrom SeuratObject CreateSeuratObject Assays GetAssayData
#' DefaultAssay<-
#' @importFrom Seurat Read10X_h5 as.sparse Assays DietSeurat as.Seurat
#'
#' @section 10X H5 File (extension \code{h5}):
#' 10X HDF5 files are supported for all versions of Cell Ranger; data is read
#' in using \code{\link[Seurat]{Read10X_h5}}. \strong{Note}: for multi-modal
#' 10X HDF5 files, only the \emph{first} matrix is read in
#'
#' @section Rds File (extension \code{rds}):
#' Rds files are supported as long as they contain one of the following data
#' types:
#' \itemize{
#'  \item A \code{\link[Seurat]{Seurat}} V3 object
#'  \item An S4 \code{\link[Matrix]{Matrix}} object
#'  \item An S3 \code{\link[base]{matrix}} object
#'  \item A \code{\link[base]{data.frame}} object
#' }
#' For S4 \code{Matrix}, S3 \code{matrix}, and \code{data.frame} objects, a
#' \code{Seurat} object will be made with
#' \code{\link[Seurat]{CreateSeuratObject}} using the default arguments
#'
#' @section h5Seurat File (extension \code{h5seurat}):
#' h5Seurat files and all of their features are fully supported. They are read
#' in via \code{\link[SeuratDisk]{LoadH5Seurat}}. \strong{Note}: only the
#' \dQuote{counts} matrices are read in and only the default assay is kept
#'
#' @inheritSection LoadH5AD AnnData H5AD File (extension \code{h5ad})
#' @export
#'
LoadFileInput <- function(path) {
  # TODO: add support for loom files
  on.exit(expr = gc(verbose = FALSE))
  type <- tolower(x = tools::file_ext(x = path))
  return(switch(
    EXPR = type,
    'h5' = {
      mat <- Read10X_h5(filename = path)
      if (is.list(x = mat)) {
        mat <- mat[[1]]
      }
      CreateSeuratObject(counts = mat, min.cells = 1, min.features = 1)
    },
    'rds' = {
      object <- readRDS(file = path)
      if (inherits(x = object, what = c('Matrix', 'matrix', 'data.frame'))) {
        object <- CreateSeuratObject(counts = as.sparse(x = object), min.cells = 1, min.features = 1)
      } else if (inherits(x = object, what = 'Seurat')) {
        if (!'RNA' %in% Assays(object = object)) {
          stop("No RNA assay provided", call. = FALSE)
        } else if (Seurat:::IsMatrixEmpty(x = GetAssayData(object = object, slot = 'counts', assay = 'RNA'))) {
          stop("No RNA counts matrix present", call. = FALSE)
        }
        object <- CreateSeuratObject(
          counts = GetAssayData(object = object[["RNA"]], slot = "counts"),
          min.cells = 1,
          min.features = 1,
          meta.data = object[[]]
        )
      } else {
        stop("The RDS file must be a Seurat object", call. = FALSE)
      }
      object
    },
    'h5ad' = LoadH5AD(path = path),
    'h5seurat' = {
      if (!requireNamespace("SeuratDisk", quietly = TRUE)) {
        stop("Loading h5Seurat files requires SeuratDisk", call. = FALSE)
      }
      hfile <- suppressWarnings(expr = SeuratDisk::Connect(filename = path))
      on.exit(expr = hfile$close_all())
      if (!'RNA' %in% names(x = hfile[['assays']])) {
        stop("Cannot find the RNA assay in this h5Seurat file", call. = FALSE)
      } else if (!'counts' %in% names(x = hfile[['assays/RNA']])) {
        stop("No RNA counts matrix provided", call. = FALSE)
      }
      object <- as.Seurat(
        x = hfile,
        assays = list('RNA' = 'counts'),
        reductions = FALSE,
        graphs = FALSE,
        images = FALSE
      )
      object <- CreateSeuratObject(
        counts = GetAssayData(object = object[["RNA"]], slot = "counts"),
        min.cells = 1,
        min.features = 1,
        meta.data = object[[]]
      )
    },
    stop("Unknown file type: ", type, call. = FALSE)
  ))
}

#' Load a diet H5AD file
#'
#' Read in only the counts matrix and (if present) metadata of an H5AD file and
#' return a \code{Seurat} object
#'
#' @inheritParams LoadFileInput
#'
#' @return A \code{Seurat} object
#'
#' @importFrom hdf5r H5File h5attr
#' @importFrom SeuratObject AddMetaData CreateSeuratObject
#'
#' @keywords internal
#'
#' @section AnnData H5AD File (extension \code{h5ad}):
#' Only H5AD files from AnnData v0.7 or higher are supported. Data is read from
#' the H5AD file in the following manner
#' \itemize{
#'  \item The counts matrix is read from \dQuote{/raw/X}; if \dQuote{/raw/X} is
#'  not present, the matrix is read from \dQuote{/X}
#'  \item Feature names are read from feature-level metadata. Feature level
#'  metadata must be an HDF5 group, HDF5 compound datasets are \strong{not}
#'  supported. If counts are read from \code{/raw/X}, features names are looked
#'  for in \dQuote{/raw/var}; if counts are read from \dQuote{/X}, features
#'  names are looked for in \dQuote{/var}. In both cases, feature names are read
#'  from the dataset specified by the \dQuote{_index} attribute, \dQuote{_index}
#'  dataset, or \dQuote{index} dataset, in that order
#'  \item Cell names are read from cell-level metadata. Cell-level metadata must
#'  be an HDF5 group, HDF5 compound datasets are \strong{not} supported.
#'  Cell-level metadata is read from \dQuote{/obs}. Cell names are read from the
#'  dataset specified by the \dQuote{_index} attribute, \dQuote{_index} dataset,
#'  or \dQuote{index} dataset, in that order
#'  \item Cell-level metadata is read from the \dQuote{/obs} dataset. Columns
#'  will be returned in the same order as in the \dQuote{column-order}, if
#'  present, or in alphabetical order. If a dataset named \dQuote{__categories}
#'  is present, then all datasets in \dQuote{__categories} will serve as factor
#'  levels for datasets present in \dQuote{/obs} with the same name (eg. a
#'  dataset named \dQuote{/obs/__categories/leiden} will serve as the levels for
#'  \dQuote{/obs/leiden}). Row names will be set as cell names as described
#'  above. All datasets in \dQuote{/obs} will be loaded except for
#'  \dQuote{__categories} and the cell names dataset
#' }
#'
LoadH5AD <- function(path) {
  if (!requireNamespace("hdf5r", quietly = TRUE)) {
    stop("Loading H5AD files requires hdf5r", call. = FALSE)
  }
  adata <- hdf5r::H5File$new(filename = path, mode = 'r')
  on.exit(expr = adata$close_all())
  Exists <- function(name) {
    name <- unlist(x = strsplit(x = name[1], split = '/', fixed = TRUE))
    hpath <- character(length = 1L)
    exists <- TRUE
    for (i in seq_along(along.with = name)) {
      hpath <- paste(hpath, name[i], sep = '/')
      exists <- adata$exists(name = hpath)
      if (isFALSE(x = exists)) {
        break
      }
    }
    return(exists)
  }
  IsMetaData <- function(md) {
    return(Exists(name = md) && inherits(x = adata[[md]], what = 'H5Group'))
  }
  GetIndex <- function(md) {
    return(
      if (adata[[md]]$attr_exists(attr_name = '_index')) {
        h5attr(x = adata[[md]], which = '_index')
      } else if (adata[[md]]$exists(name = '_index')) {
        '_index'
      } else if (adata[[md]]$exists(name = 'index')) {
        'index'
      } else {
        stop("Cannot find the rownames for '", md, "'", call. = FALSE)
      }
    )
  }
  GetRowNames <- function(md) {
    return(adata[[md]][[GetIndex(md = md)]][])
  }
  LoadMetadata <- function(md) {
    factor.cols <- if (adata[[md]]$exists(name = '__categories')) {
      names(x = adata[[md]][['__categories']])
    } else {
      NULL
    }
    index <- GetIndex(md = md)
    col.names <- names(x = adata[[md]])
    if (adata[[md]]$attr_exists(attr_name = 'column-order')) {
      tryCatch(
        expr = {
          col.order <- hdf5r::h5attr(x = adata[[md]], which = 'column-order')
          col.names <- c(
            intersect(x = col.order, y = col.names),
            setdiff(x = col.names, y = col.order)
          )
        },
        error = function(...) {
          return(invisible(x = NULL))
        }
      )
    }
    col.names <- col.names[!col.names %in% c('__categories', index)]
    df <- sapply(
      X = col.names,
      FUN = function(i) {
        x <- adata[[md]][[i]][]
        if (i %in% factor.cols) {
          x <- factor(x = x, levels = adata[[md]][['__categories']][[i]][])
        }
        return(x)
      },
      simplify = FALSE,
      USE.NAMES = TRUE
    )
    return(as.data.frame(x = df, row.names = GetRowNames(md = md)))
  }
  if (Exists(name = 'raw/X')) {
    md <- 'raw/var'
    counts <- as.matrix(x = adata[['raw/X']])
  } else if (Exists(name = 'X')) {
    md <- 'var'
    counts <- as.matrix(x = adata[['X']])
  } else {
    stop("Cannot find counts matrix")
  }
  if (!IsMetaData(md = md)) {
    stop("Cannot find feature-level metadata", call. = FALSE)
  } else if (!IsMetaData(md = 'obs')) {
    stop("Cannot find cell-level metadata", call. = FALSE)
  }
  metadata <- LoadMetadata(md = 'obs')
  rownames(x = counts) <- GetRowNames(md = md)
  colnames(x = counts) <- rownames(x = metadata)
  object <- CreateSeuratObject(counts = counts)
  if (ncol(x = metadata)) {
    object <- AddMetaData(object = object, metadata = metadata)
  }
  return(object)
}

#' Transform an NN index
#'
#' @param object Seurat object
#' @param meta.data Metadata
#' @param neighbor.slot Name of Neighbor slot
#' @param key Column of metadata to use
#'
#' @return \code{object} with transfomed neighbor.slot
#'
#' @importFrom SeuratObject Indices
#'
#' @keywords internal
#'
NNTransform <- function(
  object,
  meta.data,
  neighbor.slot = "query_ref.nn",
  key = 'ori.index'
) {
  on.exit(expr = gc(verbose = FALSE))
  ind <- Indices(object[[neighbor.slot]])
  ori.index <- t(x = sapply(
    X = 1:nrow(x = ind),
    FUN = function(i) {
      return(meta.data[ind[i, ], key])
    }
  ))
  rownames(x = ori.index) <- rownames(x = ind)
  slot(object = object[[neighbor.slot]], name = "nn.idx") <- ori.index
  return(object)
}

# Check if file is available at given URL
#
# @param url URL to file
# @param strict Ensure http code is 200
#
# @return Boolean indicating file presence
#
Online <- function(url, strict = FALSE) {
  if (isTRUE(x = strict)) {
    code <- 200L
    comp <- identical
  } else {
    code <- 404L
    comp <- Negate(f = identical)
  }
  return(comp(
    x = httr::status_code(x = httr::GET(
      url = url,
      httr::timeout(seconds = getOption('timeout')
      ))),
    y = code
  ))
}

# Make An English List
#
# Joins items together to make an English list; uses the Oxford comma for the
# last item in the list.
#
#' @inheritParams base::paste
# @param join either \dQuote{and} or \dQuote{or}
#
# @return A character vector of the values, joined together with commas and
# \code{join}
#
#' @keywords internal
#
# @examples
# \donttest{
# Oxford("red")
# Oxford("red", "blue")
# Oxford("red", "green", "blue")
# }
#
Oxford <- function(..., join = c('and', 'or')) {
  join <- match.arg(arg = join)
  args <- as.character(x = c(...))
  args <- Filter(f = nchar, x = args)
  if (length(x = args) == 1) {
    return(args)
  } else if (length(x = args) == 2) {
    return(paste(args, collapse = paste0(' ', join, ' ')))
  }
  return(paste0(
    paste(args[1:(length(x = args) - 1)], collapse = ', '),
    paste0(', ', join, ' '),
    args[length(x = args)]
  ))
}

# Cluster preservation score
#
# @param query Query object
# @param ds.amount Amount to downsample query
# @param max.dims
# @return Returns
#
#' @importFrom SeuratObject Cells Idents Indices as.Neighbor
#' @importFrom Seurat RunPCA FindNeighbors FindClusters MinMax
#
#' @keywords internal
#
#
ClusterPreservationScore <- function(query, ds.amount, max.dims) {
  query <- DietSeurat(object = query, assays = "refAssay", scale.data = TRUE, counts = FALSE, dimreducs = "integrated_dr")
  if (ncol(x = query) > ds.amount) {
    query <- subset(x = query, cells = sample(x = Cells(x = query), size = ds.amount))
  }
  dims <- min(50, max.dims)
  query <- RunPCA(object = query, npcs = dims, verbose = FALSE)
  query <- FindNeighbors(
    object = query,
    reduction = 'pca',
    dims = 1:dims,
    graph.name = paste0("pca_", c("nn", "snn"))
  )
  query[["orig_neighbors"]] <- as.Neighbor(x = query[["pca_nn"]])
  query <- FindClusters(object = query, resolution = 0.6, graph.name = 'pca_snn')
  query <- FindNeighbors(
    object = query,
    reduction = 'integrated_dr',
    dims = 1:dims,
    return.neighbor = TRUE,
    graph.name ="integrated_neighbors_nn"
  )
  ids <- Idents(object = query)
  integrated.neighbor.indices <- Indices(object = query[["integrated_neighbors_nn"]])
  proj_ent <- unlist(x = lapply(X = 1:length(x = Cells(x = query)), function(x) {
    neighbors <- integrated.neighbor.indices[x, ]
    nn_ids <- ids[neighbors]
    p_x <- prop.table(x = table(nn_ids))
    nn_entropy <- sum(p_x * log(x = p_x), na.rm = TRUE)
    return(nn_entropy)
  }))
  names(x = proj_ent) <- Cells(x = query)
  orig.neighbor.indices <- Indices(object = query[["orig_neighbors"]])
  orig_ent <- unlist(x = lapply(X = 1:length(x = Cells(x = query)), function(x) {
    neighbors <- orig.neighbor.indices[x, ]
    nn_ids <- ids[neighbors]
    p_x <- prop.table(x = table(nn_ids))
    nn_entropy <- sum(p_x * log(x = p_x), na.rm = TRUE)
    return(nn_entropy)
  }))
  names(x = orig_ent) <- Cells(x = query)
  stat <- median(
    x = tapply(X = orig_ent, INDEX = ids, FUN = mean) -
      tapply(X = proj_ent, INDEX = ids, FUN = mean)
  )
  if (stat <= 0) {
    stat <- 5.00
  } else {
    stat <- -1 * log2(x = stat)
    stat <- MinMax(data = stat, min = 0.00, max = 5.00)
  }
  return(stat)
}
