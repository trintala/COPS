#' Dispersion Separability Criterion
#'
#' Used by TCGA Batch Effects Viewer \url{https://bioinformatics.mdanderson.org/public-software/tcga-batch-effects/}.
#' Based on \url{http://citeseerx.ist.psu.edu/viewdoc/summary?doi=10.1.1.95.1128}.
#' Can be used to measure batch effect.
#'
#' @param data_matrix numeric matrix, samples on columns
#' @param batch_label categorical variable, must be vector
#'
#' @return Returns the DSC of \code{data_matrix} with respect to \code{batch_label} as a scalar value
#' @export
DSC <- function(data_matrix, batch_label) {
  # Dispersion within batches
  Sw <- base::scale(t(data_matrix), center = TRUE, scale = FALSE)**2 / dim(data_matrix)[2] # vectorized
  Dw <- base::sqrt(sum(Sw))
  #Dw <- sqrt(sum(sapply(split(data.frame(t(data_matrix)), batch_label), function(x) sum(diag(cov(x))))))
  # Dispersion between batches
  M = apply(data_matrix, 1, mean)
  mean_var <- function(x) {o <- apply(x, 2, mean) - M; return(sum(o**2))} # vectorized
  #mean_var <- function(x) {o <- apply(x, 2, mean) - M; return(sum(diag(o%*%t(o))))}
  Sb <- sapply(split(data.frame(t(data_matrix)), batch_label), mean_var)
  Db = base::sqrt(sum(Sb))
  return(Db/Dw)
}

#' Average Jaccard dissimilarity coefficient between multiple clustering results
#'
#' Measures the stability of a given clustering method when combined with
#' cross-validation or bootstrap by estimating the repeatability of clustering results.
#'
#' @param clustering_list \code{list} of clustering vectors
#'
#' @return Returns a scalar value giving the mean jaccard distance between clustering vectors
#' @importFrom clusteval cluster_similarity
#' @export
jdist <- function(clustering_list) {
  n_runs <- length(clustering_list)
  jdist <- base::array(NA, dim = c(n_runs, n_runs))
  for (i in 1:(n_runs-1)) {
    for (j in (i+1):n_runs) {
      jdist[i,j] <- 1 - clusteval::cluster_similarity(clustering_list[[i]],
                                                      clustering_list[[j]])
    }
  }
  mean_dist <- mean(jdist, na.rm = TRUE)
  return(mean_dist)
}

#' Clustering stability evaluation
#'
#' Performs stability analysis on cross-validated clusterings using \code{\link{jdist}}.
#'
#' Default settings work with \code{\link{clusteval_cv}} output 'clust'. \cr
#' Assumes all clustering vectors (samples) appear in the same order.
#'
#' @param clust clustering \code{data.frame} such as returned by \code{\link{clusteval_cv}}
#' @param by vector of column names to keep
#' @param by2 vector of column names to split by, "run" and "fold" by default
#' @param parallel if TRUE, run in parallel (not working currently)
#' @param ... extra arguments are ignored
#'
#' @return Returns a \code{data.frame} where each row corresponds to clustering stability
#'         with respect to kept column variables
#' @export
#' @importFrom plyr ddply here
#'
stability_eval <- function(clust,
                           by = c("k", "m"),
                           by2 = colnames(clust)[!colnames(clust) %in% c("cluster", "id", by)],
                           parallel = FALSE,
                           ...)
{
  stability <- plyr::ddply(clust,
                           by,
                           here(function(x) jdist(split(x$cluster, x[by2]))),
                           .parallel = FALSE, # TODO: fix parallelization
                           .paropts = list(.export = c("jdist")))#, "by2")))
  #.packages = c("clusteval") # Not necessary as we access namespace directly
  colnames(stability)[ncol(stability)] <- "jdist"

  return(stability)
}

#' Categorical variable association estimates
#'
#' Three non-clustering batch effect estimators put together. \cr
#' Can be used for other purposes as well.
#'
#' @param dat data matrix, samples on columns
#' @param class vector or matrix where columns are categorical variables
#' @param n_pc_max maximum number of principal components to analyze
#' @param ... extra arguments are ignored
#'
#' @return Returns a \code{list} containing \code{\link[kBET]{batch_sil}},
#'         \code{\link[KBET]{pcRegression}} and \code{\link{DSC}}
#'         computed for each column of \code{class}
#' @export
#' @importFrom FactoMineR PCA
#' @importFrom kBET batch_sil
#' @importFrom kBET pcRegression
class_associations <-  function(dat, class, n_pc_max = 10, ...){
  out <- list()
  if (is.null(dim(class))) class <- cbind(class, c())

  pca_silh <- list()
  pca_reg <- list()
  DSC_res <- c()
  for (i in 1:ncol(class)) {
    # PCA based
    dat_pca <- FactoMineR::PCA(t(dat),
                               scale.unit = FALSE,
                               ncp = min(n_pc_max, nrow(dat)),
                               graph = FALSE)
    pca_silh[[i]] <- kBET::batch_sil(list(x = dat_pca$ind$coord),
                                     class[,i],
                                     nPCs = min(n_pc_max, nrow(dat)))
    pca_reg[[i]] <- suppressWarnings(kBET::pcRegression(list(x = dat_pca$ind$coord),
                                       class[,i],
                                       n_top = min(n_pc_max, nrow(dat))))

    # Other
    DSC_res[i] <- DSC(dat, class[,i])
  }
  if (!is.null(dimnames(class))) {
    names(pca_silh) <- dimnames(class)[[2]]
    names(pca_reg) <- dimnames(class)[[2]]
    names(DSC_res) <- dimnames(class)[[2]]
  }
  out <- list(PCA_silhouette = pca_silh,
              PCA_regression = pca_reg,
              DSC = DSC_res)
  return(out)
}


#' Cross-validation of clustering evaluation
#'
#' Performs cross-validation to estimate clustering stability and the spread of other metrics.
#'
#' Stability of clustering should decrease with data size, which means that using
#' fewer folds for cross-validation is more difficult i.e. should be less stable.
#'
#' @param dat data matrix, samples on columns
#' @param batch_label vector or matrix where columns are categorical variables
#' @param CVFOLDS number of cross-validation folds
#' @param RUNS number of times to repeat cross-validation
#' @param ... extra arguments are passed through to clustering_evaluation
#'
#' @return Returns a \code{list} of \code{data.frames} containing \code{\link{clustering_evaluation}} outputs for every
#'         combination of CV run, CV fold, clustering method and number of clusters
#' @export
#' @importFrom foreach foreach %do% %dopar%
#' @importFrom stats dist chisq.test
clusteval_cv <- function(dat,
                         batch_label = NULL,
                         CVFOLDS = 2,
                         RUNS = 10,
                         #significance = 0.05,
                         ...)
{
  # TODO: redirect extra arguments
  # eargs <- list(...)

  # Initialize output aggregates
  clust <- data.frame()
  metrics <- data.frame()
  if (!is.null(batch_label)) chisq_pval <- data.frame()

  # Compute distances between points once.
  # Used for test set clustering via nearest neighbor
  # TODO: find a better method for 'predicting'
  distances <- as.matrix(dist(t(dat)))

  cv_ind <- foreach(1:RUNS, .combine = "cbind") %dopar% sample(1:ncol(dat)) %% CVFOLDS + 1

  cfun <- function(a,b) foreach(i = names(b), .combine = "c") %do% {
    temp <- list()
    temp[[i]] <- rbind(a[[i]],b[[i]]) # "temp[[i]] <- " retains names for indexing
    temp
  }
  out_list <- foreach(i = 1:prod(RUNS, CVFOLDS),
                      .combine = cfun,
                      .export = c("clustering_evaluation"),
                      .packages = c("clValid", "reshape2")) %dopar% {
                        out <- list()
                        run <- (i-1) %/% CVFOLDS + 1
                        cvf <- (i-1) %% CVFOLDS + 1
                        clust_res <- clustering_evaluation(dat[,cv_ind[,run] != cvf], batch_label = NULL, ...)

                        # Use nearest neighbour to cluster validation set
                        #val_nn <- FNN::get.knnx(dat[cv_ind[,run] != cvf,], dat[cv_ind[,run] == cvf,], k = 1)
                        val_nn <- apply(distances[cv_ind[,run] != cvf, cv_ind[,run] == cvf], 2, which.min)
                        val_clust <- clust_res$clusters[val_nn,,]

                        clust_all <- array(NA, dim = c(ncol(dat), dim(clust_res$clusters)[2:3]))
                        clust_all[cv_ind[,run] != cvf,,] <- clust_res$clusters
                        clust_all[cv_ind[,run] == cvf,,] <- val_clust

                        dimnames(clust_all) <- c(list(id = colnames(dat)), dimnames(clust_res$clusters)[2:3])

                        out$clust <- data.frame(run = run,
                                                fold = cvf,
                                                reshape2::melt(clust_all, value.name = "cluster"))

                        out$metrics <- data.frame(run = run,
                                                  fold = cvf,
                                                  reshape2::melt(clust_res$metrics))

                        if (!is.null(batch_label)) {
                          if (is.null(dim(batch_label))) batch_label <- cbind(batch_label, c())
                          chisq_pval <- list()
                          for (i in 1:dim(batch_label)[2]) {
                            i_function <- function(x) suppressWarnings(chisq.test(table(x, batch_label[,i])))$p.value
                            if (!is.null(colnames(batch_label))) {
                              i_label <- paste0("p", colnames(batch_label)[i])
                            } else {
                              i_label <- paste0("p", i)
                            }
                            chisq_pval_fold <- apply(clust_all, 2:3, i_function)
                            dimnames(chisq_pval_fold) <- dimnames(clust_res$clusters)[2:3]
                            chisq_pval[[i]] <- data.frame(run = run,
                                                          fold = cvf,
                                                          reshape2::melt(chisq_pval_fold,
                                                                         value.name = i_label))
                          }
                          out$chisq_pval <- Reduce(plyr::join, chisq_pval)
                        }
                        out
                      }

  return(out_list)
}


#' Clustering, internal evaluation and batch effect estimation
#'
#' Single embedding or dataset evaluation
#'
#' Supported clustering methods are:
#' \itemize{
#' \item "hierarchical" -
#' \item "diana" -
#' \item "agnes" -
#' \item "kmeans" -
#' \item "pam" -
#' \item "sota" -
#' }
#' The clustering methods are interfaced through \code{\link[clValid]{clValid}} so please refer to
#' their documentation for options on metrics.
#'
#' @param dat data matrix with samples on columns
#' @param batch_label must be categorical vector, OPTIONAL
#' @param n_clusters vector of integers, numbers of clusters to be generated
#' @param cluster_methods vector of clustering method names, see details for options
#' @param metric distance metric used for clustering, see details for options
#' @param ... extra arguments are ignored currently
#'
#' @return Returns a \code{list} containing clusters, metrics, and
#'         \code{\link[stats]{chisq.test}} p-values
#'         if batch_label was supplied
#' @export
#' @importFrom stats chisq.test cutree
clustering_evaluation <- function(dat,
                                  batch_label = NULL,
                                  n_clusters = 2:5,
                                  cluster_methods = c("hierarchical","pam","diana","kmeans"),
                                  metric = "euclidean",
                                  ...) {
  out <- clValid(t(dat),
                 n_clusters,
                 clMethods = cluster_methods,
                 metric = metric,
                 validation="internal")
  names(dimnames(out@measures)) <- c("metric", "k", "m")
  # Extract clusters into array
  clusters <- array(dim = c(dim(dat)[2], length(n_clusters), length(cluster_methods)))
  dimnames(clusters) <- list(id = colnames(dat), k = n_clusters, m = cluster_methods)
  for (j in 1:length(cluster_methods)) {
    temp <- clusters(out, cluster_methods[j])
    for (i in 1:length(n_clusters)) {
      if (cluster_methods[j] %in% c("hierarchical", "diana", "agnes")) {
        temp_k <- cutree(temp, n_clusters[i])
      } else if (cluster_methods[j] == "pam") {
        temp_k <- temp[[i]]$clustering
      } else if (cluster_methods[j] == "kmeans") {
        temp_k <- temp[[i]]$cluster
      } else if (cluster_methods[j] == "sota") {
        temp_k <- temp[[i]]$clust
      } else {
        stop(paste("Unsupported method:", cluster_methods[j]))
      }
      clusters[,i,j] <- temp_k
    }
  }
  if (!is.null(batch_label)) {
    # For each clustering do:
    # chisq.test with respect to batch
    chisq_pval <- array(dim = c(length(n_clusters), length(cluster_methods)))
    for (j in 1:length(cluster_methods)) {
      for (i in 1:length(n_clusters)) {
        chisq_pval[i,j] <- suppressWarnings(chisq.test(table(clusters[,i,j], batch_label)))$p.value
      }
    }
    return(list(clusters = clusters, metrics = out@measures, chisq_pval = chisq_pval))
  }
  return(list(clusters = clusters, metrics = out@measures))
}
