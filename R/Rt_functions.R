get_immunity_ratios <- function(out, max_date = NULL) {

  mixing_matrix <- squire:::process_contact_matrix_scaled_age(
    out$pmcmc_results$inputs$model_params$contact_matrix_set[[1]],
    out$pmcmc_results$inputs$model_params$population
  )

  dur_ICase <- out$parameters$dur_ICase
  dur_IMild <- out$parameters$dur_IMild
  prob_hosp <- out$parameters$prob_hosp

  # assertions
  squire:::assert_single_pos(dur_ICase, zero_allowed = FALSE)
  squire:::assert_single_pos(dur_IMild, zero_allowed = FALSE)
  squire:::assert_numeric(prob_hosp)
  squire:::assert_numeric(mixing_matrix)
  squire:::assert_square_matrix(mixing_matrix)
  squire:::assert_same_length(mixing_matrix[,1], prob_hosp)

  if(sum(is.na(prob_hosp)) > 0) {
    stop("prob_hosp must not contain NAs")
  }

  if(sum(is.na(mixing_matrix)) > 0) {
    stop("mixing_matrix must not contain NAs")
  }

  index <- squire:::odin_index(out$model)
  pop <- out$parameters$population

  if(is.null(max_date)) {
    max_date <- max(out$pmcmc_results$inputs$data$date)
  }
  t_now <- which(as.Date(rownames(out$output)) == max_date)
  prop_susc <- lapply(seq_len(dim(out$output)[3]), function(x) {
    t(t(out$output[seq_len(t_now), index$S, x])/pop)
  } )

  relative_R0_by_age <- prob_hosp*dur_ICase + (1-prob_hosp)*dur_IMild

  adjusted_eigens <- lapply(prop_susc, function(x) {

    unlist(lapply(seq_len(nrow(x)), function(y) {
      if(any(is.na(x[y,]))) {
        return(NA)
      } else {
        Re(eigen(mixing_matrix*x[y,]*relative_R0_by_age)$values[1])
      }
    }))

  })

  betas <- lapply(out$replicate_parameters$R0, function(x) {
    squire:::beta_est(squire_model = out$pmcmc_results$inputs$squire_model,
                      model_params = out$pmcmc_results$inputs$model_params,
                      R0 = x)
  })

  ratios <- lapply(seq_along(betas), function(x) {
    (betas[[x]] * adjusted_eigens[[x]]) / out$replicate_parameters$R0[[x]]
  })

  return(ratios)
}




rt_data_immunity_supp <- function(mod_res) {

  out <- mod_res$fit_Model
  iso3c <- "ZMB"

  if("pmcmc_results" %in% names(out)) {
    wh <- "pmcmc_results"
  } else {
    wh <- "scan_results"
  }

  date <- max(as.Date(out$pmcmc_results$inputs$data$date))
  date_0 <- date

  # impact of immunity ratios
  ratios <- get_immunity_ratios(out)

  # create the Rt data frame
  rts <- lapply(seq_len(length(out$replicate_parameters$R0)), function(y) {
    # browser()
    tt <- squire:::intervention_dates_for_odin(dates = out$interventions$date_R0_change,
                                               change = out$interventions$R0_change,
                                               start_date = out$replicate_parameters$start_date[y],
                                               steps_per_day = 1/out$parameters$dt)

    if(wh == "scan_results") {
      Rt <- c(out$replicate_parameters$R0[y],
              vapply(tt$change, out[[wh]]$inputs$Rt_func, numeric(1),
                     R0 = out$replicate_parameters$R0[y], Meff = out$replicate_parameters$Meff[y]))
    } else {
      Rt <- squire:::evaluate_Rt_pmcmc(
        R0_change = tt$change,
        date_R0_change = tt$dates,
        R0 = out$replicate_parameters$R0[y],
        pars = as.list(out$replicate_parameters[y,]),
        Rt_args = out$pmcmc_results$inputs$Rt_args)
    }

    df <- data.frame(
      "Rt" = Rt,
      "Reff" = Rt*tail(na.omit(ratios[[y]]),length(Rt)),
      "R0" = na.omit(Rt)[1]*tail(na.omit(ratios[[y]]),length(Rt)),
      "date" = tt$dates,
      "iso" = iso3c,
      rep = y,
      stringsAsFactors = FALSE)
    df$pos <- seq_len(nrow(df))
    return(df)
  } )

  rt <- do.call(rbind, rts)
  rt$date <- as.Date(rt$date)

  rt <- rt[,c(5,4,1,2,3,6,7)]

  new_rt_all <- rt %>%
    group_by(iso, rep) %>%
    arrange(date) %>%
    complete(date = seq.Date(min(rt$date), date_0, by = "days"))

  column_names <- colnames(new_rt_all)[-c(1,2,3)]
  new_rt_all <- fill(new_rt_all, all_of(column_names), .direction = c("down"))
  new_rt_all <- fill(new_rt_all, all_of(column_names), .direction = c("up"))

  suppressMessages(sum_rt <- group_by(new_rt_all, iso, date) %>%
                     summarise(Rt_min = quantile(Rt, 0.025),
                               Rt_q25 = quantile(Rt, 0.25),
                               Rt_q75 = quantile(Rt, 0.75),
                               Rt_max = quantile(Rt, 0.975),
                               Rt_median = median(Rt),
                               Rt = mean(Rt),
                               R0_min = quantile(R0, 0.025),
                               R0_q25 = quantile(R0, 0.25),
                               R0_q75 = quantile(R0, 0.75),
                               R0_max = quantile(R0, 0.975),
                               R0_median = median(R0),
                               R0 = mean(R0),
                               Reff_min = quantile(Reff, 0.025),
                               Reff_q25 = quantile(Reff, 0.25),
                               Reff_q75 = quantile(Reff, 0.75),
                               Reff_max = quantile(Reff, 0.975),
                               Reff_median = median(Reff),
                               Reff = mean(Reff)))

  return(sum_rt)
}
