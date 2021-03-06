# ==================================================================================================
# Helpers
# ==================================================================================================

# Function to split indices for the symmetric, parallel, proxy case
split_parallel_symmetric <- function(n, num_workers, adjust = 0L) {
    if (num_workers <= 2L || n <= 4L) {
        mid_point <- as.integer(n / 2)
        # indices for upper part of the lower triangular
        ul_trimat <- 1L:mid_point + adjust
        # indices for lower part of the lower triangular
        ll_trimat <- (mid_point + 1L):n + adjust
        # put triangular parts together for load balance
        trimat <- list(ul = ul_trimat, ll = ll_trimat)

        attr(trimat, "trimat") <- TRUE
        trimat <- list(trimat)

        mid_point <- mid_point + adjust
        attr(ul_trimat, "rows") <- ll_trimat
        mat <- list(ul_trimat)

        ids <- c(trimat, mat)

    } else {
        mid_point <- as.integer(n / 2)

        # recursion
        rec1 <- split_parallel_symmetric(mid_point, as.integer(num_workers / 4), adjust)
        rec2 <- split_parallel_symmetric(n - mid_point, as.integer(num_workers / 4), mid_point + adjust)

        endpoints <- parallel::splitIndices(mid_point, max(length(rec1) + length(rec2), num_workers))
        endpoints <- endpoints[lengths(endpoints) > 0L]
        mat <- lapply(endpoints, function(ids) {
            ids <- ids + adjust
            attr(ids, "rows") <- (mid_point + 1L):n + adjust
            ids
        })

        ids <- c(rec1, rec2, mat)
    }

    chunk_sizes <- unlist(lapply(ids, function(x) {
        if (is.null(attr(x, "trimat"))) length(x) else median(lengths(x))
    }))

    # return
    ids[sort(chunk_sizes, index.return = TRUE)$ix]
}

# ==================================================================================================
# Return a custom distance function that calls registered functions of proxy
# ==================================================================================================

ddist2 <- function(distance, control) {
    # I need to re-register any custom distances in each parallel worker
    dist_entry <- proxy::pr_DB$get_entry(distance)
    symmetric <- isTRUE(control$symmetric)

    # Closures capture the values of the objects from the environment where they're created
    distfun <- function(x, centroids = NULL, ...) {
        x <- tslist(x)
        if (!is.null(centroids)) centroids <- tslist(centroids)
        if (length(x) == 1L && is.null(centroids)) { # nocov start
            return(structure(matrix(0, 1L, 1L),
                             class = "crossdist",
                             method = toupper(distance),
                             dimnames = list(names(x), names(x))))
        } # nocov end

        if (!is.null(control$distmat)) {
            if (!inherits(control$distmat, "Distmat")) stop("Invalid distance matrix in control.")
            # internal class, sparse or full
            i <- 1L:length(x)
            j <- if (is.null(centroids)) i else control$distmat$id_cent
            d <- control$distmat[i, j, drop = FALSE]

        } else {
            # distmat not available, calculate it
            # Extra distance parameters in case of parallel computation
            # They can be for the function or for proxy::dist
            dots <- list(...)

            # Added defaults
            if (is.null(dots$window.size))
                dots$window.type <- "none"
            else if (is.null(dots$window.type))
                dots$window.type <- "slantedband"

            dots$error.check <- FALSE

            # dtw uses L2 by default, but in dtwclust I want dtw to use L1 by default
            # Important for multivariate series
            if (toupper(dist_entry$names[1L]) == "DTW" && is.null(dots$dist.method))
                dots$dist.method <- "L1"

            # If the function doesn't have '...', remove invalid arguments from 'dots'
            valid_args <- names(dots)
            if (is.function(dist_entry$FUN)) {
                if (!has_dots(dist_entry$FUN))
                    valid_args <- union(names(formals(proxy::dist)), names(formals(dist_entry$FUN)))

            } else {
                valid_args <- names(formals(proxy::dist))
            }
            dots <- dots[intersect(names(dots), valid_args)]

            # variables/functions from the parent environments that should be exported
            export <- c("distance", "dist_entry", "check_consistency", "enlist", "subset_dots")

            if (tolower(distance) %in% distances_included) {
                # DTWCLUST DISTANCES, LET THEM HANDLE OPTIMIZATIONS
                d <- do.call(proxy::dist,
                             enlist(x = x,
                                    y = centroids,
                                    method = distance,
                                    dots = dots),
                             TRUE)

            } else if (is.null(centroids) && symmetric && !isTRUE(dots$pairwise)) {
                if (dist_entry$loop && foreach::getDoParWorkers() > 1L) {
                    # WHOLE SYMMETRIC DISTMAT IN PARALLEL
                    # Only half of it is computed
                    # proxy can do this if y = NULL, but not in parallel
                    len <- length(x)
                    seed <- get0(".Random.seed", .GlobalEnv, mode = "integer")
                    d <- bigmemory::big.matrix(len, len, "double", 0)
                    d_desc <- bigmemory::describe(d)
                    assign(".Random.seed", seed, .GlobalEnv)

                    ids <- integer() # 'initialize', so CHECK doesn't complain about globals
                    foreach(
                        ids = split_parallel_symmetric(len, foreach::getDoParWorkers()),
                        .combine = c,
                        .multicombine = TRUE,
                        .noexport = c("d"),
                        .packages = c(control$packages, "bigmemory"),
                        .export = export
                    ) %op% {
                        if (!check_consistency(dist_entry$names[1L], "dist"))
                            do.call(proxy::pr_DB$set_entry, dist_entry, TRUE)

                        dd <- bigmemory::attach.big.matrix(d_desc)

                        if (isTRUE(attr(ids, "trimat"))) {
                            # assign upper part of lower triangular
                            ul <- ids$ul
                            if (length(ul) > 1L)
                                dd[ul,ul] <- base::as.matrix(do.call(
                                    proxy::dist,
                                    enlist(x = x[ul],
                                           y = NULL,
                                           method = distance,
                                           dots = dots),
                                    TRUE
                                ))
                            # assign lower part of lower triangular
                            ll <- ids$ll
                            if (length(ll) > 1L)
                                dd[ll,ll] <- base::as.matrix(do.call(
                                    proxy::dist,
                                    enlist(x = x[ll],
                                           y = NULL,
                                           method = distance,
                                           dots = dots),
                                    TRUE
                                ))
                        } else {
                            rows <- attr(ids, "rows")
                            mat_chunk <- base::as.matrix(do.call(
                                proxy::dist,
                                enlist(x = x[rows],
                                       y = x[ids],
                                       method = distance,
                                       dots = dots),
                                TRUE
                            ))
                            # assign matrix chunks
                            dd[rows,ids] <- mat_chunk
                            dd[ids,rows] <- t(mat_chunk)
                        }

                        # return from parallel foreach
                        NULL
                    }

                    d <- d[,]
                    attr(d, "class") <- "crossdist"
                    attr(d, "dimnames") <- list(names(x), names(x))

                } else {
                    # WHOLE SYMMETRIC DISTMAT WITH CUSTOM LOOP OR SEQUENTIAL proxy LOOP
                    d <- base::as.matrix(do.call(proxy::dist,
                                                 enlist(x = x,
                                                        y = NULL,
                                                        method = distance,
                                                        dots = dots),
                                                 TRUE))
                    class(d) <- "crossdist"
                }

            } else {
                # WHOLE DISTMAT OR SUBDISTMAT OR NOT SYMMETRIC
                if (is.null(centroids)) centroids <- x
                dim_names <- list(names(x), names(centroids))
                x <- split_parallel(x)

                if (isTRUE(dots$pairwise)) {
                    centroids <- split_parallel(centroids)
                    validate_pairwise(x, centroids)
                    combine <- c

                } else {
                    centroids <- lapply(1L:foreach::getDoParWorkers(), function(dummy) { centroids })
                    if (length(centroids) > length(x)) centroids <- centroids[1L:length(x)]
                    combine <- rbind
                }

                d <- foreach(x = x, centroids = centroids,
                             .combine = combine,
                             .multicombine = TRUE,
                             .packages = control$packages,
                             .export = export) %op% {
                                 if (!check_consistency(dist_entry$names[1L], "dist"))
                                     do.call(proxy::pr_DB$set_entry, dist_entry, TRUE)

                                 # 'dots' has all extra arguments that are valid
                                 dd <- do.call(proxy::dist,
                                               enlist(x = x,
                                                      y = centroids,
                                                      method = distance,
                                                      dots = dots),
                                               TRUE)

                                 dd
                             }

                if (isTRUE(dots$pairwise)) {
                    attr(d, "class") <- "pairdist"

                } else {
                    attr(d, "class") <- "crossdist"
                    attr(d, "dimnames") <- dim_names
                }
            }
        }

        attr(d, "method") <- toupper(distance)
        attr(d, "call") <- NULL

        # return
        d
    }

    distfun
}
