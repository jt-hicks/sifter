#' Run a pMCMC
#'
#' This function sets up and runs a particle MCMC that uses Dust, Odin and MCState
#'
#' @param data_raw Time series data to fit model
#' @param n_particles Number of particles to be used in pMCMC (default = 200)
#' @param init_EIR A single value or a dataframe with two columns (time and EIR)
#'                  to specify historical malaria transmission levels before
#'                  data collection began.
#' @param target_prev Return an initial EIR value (from the equilibrium solution),
#'                    given a target prevalence in under 5yos
#' @param proposal_matrix Proposal matrix for MCMC parameters
#' @param max_param Ceiling for proposed stochastic parameter (either EIR or betaa) values (default = 1000)
#' @param prop_treated Proportion of clinical cases that receive effective treatment (default = 40%)
#' @param max_steps Maximum steps for particle filter (default = 1e7)
#' @param atol atol for particle filter (default = 1e-3)
#' @param rtol rtol for particle filter (default = 1e-6)
#' @param n_steps Number of MCMC steps in a single chain (default = 500)
#' @param n_threads Number of processing threads (default = 4)
#' @param n_chains Number of chains (default = 1)
#' @param n_workers Number of workers (default = 4)
#' @param lag_rates Number of delay compartments (default = 10)
#' @param state_check Run equilibrium checks, if state_check = 1, returns expected deriv values which should equal 0 and sets stochastic model to have EIR constant at init_EIR
#'                    If state_check = 1 and seasonality_on = 1, then the deterministic seasonal model is still run, but theta2 is forced to 1, forcing a constant seasonality profile
#'                    If state_check = 0, no values are printed
#' @param country Name of country (needed if using seasonality model)
#' @param admin_unit Name of administrative unit (needed if using seasonality model)
#' @param preyears Length of time in years the deterministic seasonal model should run before Jan 1 of the year observations began (default = 2)
#' @param seasonality_on Toggle seasonality model run before observed time period (default = 1)
#' @param seasonality_check Toggle saving values of seasonality equilibrium (default = 1)
#' @param seed Allows user to specify a seed (default = 1L)
#' @param start_pf_time Number of days before first observation that particle filter will start (default = 30)
#' @param particle_tune Logical to determine if tuning the number of particles should be performed.
#' @param stoch_param The parameters which will stochastically update over the time series, 'EIR' or 'betaa'.
#' @param comparison The comparison function to be used. Either 'u5' which
#'          equates the observed prevalence to prevalence under 5 years old in
#'          the model or 'pgmg' which calculates prevalence in primigravid and
#'          multigravid pregnant women for comparison with observed ANC data.
#' @export
run_pmcmc <- function(data_raw=NULL,
                      data_raw_pg=NULL,
                      data_raw_mg=NULL,
                      init_EIR = 10,
                      target_prev=NULL,
                      target_prev_group='5.10',
                      n_particles=200,
                      proposal_matrix,
                      max_param=1000,
                      prop_treated = 0.4,
                      # EIR_vol,
                      # proposal_dist,
                      # init_EIR = 100,
                      max_steps = 1e7,
                      atol = 1e-6,
                      rtol = 1e-6,
                      n_steps = 500,
                      n_threads = 4,
                      n_chains = 1,
                      n_workers = 1,
                      lag_rates = 10,
                      state_check = 0,## Run equilibrium checks
                      # If state_check = 1, returns expected deriv values which should equal 0 and sets stochastic model to have EIR constant at init_EIR
                      # If state_check = 1 and seasonality_on = 1, then the deterministic seasonal model is still run, but theta2 is forced to 1, forcing a constant seasonality profile
                      # If state_check = 0, no values are printed
                      country = NULL,
                      admin_unit = NULL,
                      preyears = 2, #Length of time in years the deterministic seasonal model should run before Jan 1 of the year observations began
                      seasonality_on = 1,  ## state_check = 1 runs a deterministic seasonal model before running the stochastic model to get more realistic immunity levels
                      ## If seasonality_on = 0, runs the stochastic model based on the standard equilibrium solution
                      seasonality_check = 0,##If 1, saves values of seasonality equilibrium
                      seed = 1L,
                      start_pf_time = 30,
                      particle_tune = FALSE,
                      stoch_param = c('EIR','betaa'),
                      comparison = c('u5','pgmg','pgsg')){
  ##Merge primigrav and multigrav datasets if necessary.
  if(comparison=='pgmg' | comparison=='pgsg'){
      data_raw <- dplyr::left_join(data_raw_pg,data_raw_mg,by=c('month'),suffix = c('.pg','.mg'))
  }
  Sys.setenv("MC_CORES"=n_threads)

  ## Modify dates from data
  # str(data_raw$month)
  # print(data_raw$month)
  start_obs <- min(zoo::as.Date(zoo::as.yearmon(data_raw$month)))#Month of first observation (in Date format)
  # cat('start_obs: ',as.character(start_obs),'\n')
  time_origin <- zoo::as.Date(paste0(lubridate::year(start_obs)-1,'-01-01')) #January 1 of year before observation (in Date format)
  # cat('time_origin: ',as.character(time_origin),'\n')
  data_raw_time <- data_raw
  data_raw_time$date <- zoo::as.Date(zoo::as.yearmon(data_raw$month), frac = 0.5) #Convert dates to middle of month
  data_raw_time$t <- as.integer(difftime(data_raw_time$date,time_origin,units="days")) #Calculate date as number of days since January 1 of year before observation
  # cat('First observed time: ',min(data_raw_time$t),'\n')
  initial_time <- min(data_raw_time$t) - start_pf_time #Start particle filter a given time (default = 30d) before first observation
  # cat('initial_time: ',initial_time,'\n')
  #Create daily sequence from initial_time to end of observations
  #This is so the trajector histories return daily values (otherwise it returns
  #model values only at the dates of observation)
  # time_list <- data.frame(t=initial_time:max(data_raw_time$t))
  # data_raw_time <- dplyr::left_join(time_list,data_raw_time,by='t')
  start_stoch <- lubridate::floor_date(zoo::as.Date(min(data_raw_time$date) - start_pf_time), unit='month') #Start of stochastic schedule; needs to start when particle filter starts
  # cat('start_stoch: ',as.character(start_stoch),'\n')
  # data_raw_time <- plyr::rbind.fill(data.frame(t=initial_time),data_raw_time)
  data <- mcstate::particle_filter_data(data_raw_time, time = "t", rate = NULL, initial_time = initial_time) #Declares data to be used for particle filter fitting
  # print('Data processed')
  ## Provide schedule for changes in stochastic process (in this case EIR)
  ## Converts a sequence of dates (from start_stoch to 1 month after last observation point) to days since January 1 of the year before observation
  stoch_update_dates <- c(start_stoch,seq.Date(start_obs,max(as.Date(data_raw_time$date+30),na.rm = TRUE),by='month'))
  stochastic_schedule <- as.integer(difftime(stoch_update_dates,time_origin,units="days"))
  # cat('stochastic_schedule:\n',stochastic_schedule,'\n')
  # print('stochastic_schedule assigned')


  #Provide age categories, proportion treated, and number of heterogeneity brackets
  init_age <- c(0, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3.5, 5, 7.5, 10, 15, 20, 30, 40, 50, 60, 70, 80)
  het_brackets <- 5

  #Create model parameter list. Also loads seasonality profile data file to match to desired admin_unit and country
  mpl_pf <- sifter::model_param_list_create(init_age = init_age,
                                    prop_treated = prop_treated,
                                    het_brackets = het_brackets,
                                    max_param = max_param,
                                    target_prev = target_prev,
                                    target_prev_group = target_prev_group,
                                    state_check = state_check,
                                    lag_rates = lag_rates,
                                    country = country,
                                    admin_unit = admin_unit,
                                    start_stoch = start_stoch,
                                    time_origin = time_origin,
                                    seasonality_on = seasonality_on,
                                    preyears = preyears,
                                    particle_tune = particle_tune)
  # print('model parameter list created')
  # print(mpl_pf$state_check)
  # print(mpl_pf$ssa0)

  ## If a deterministic seasonal model is needed prior to the stochastic model, this loads the deterministic odin model
  det_model <- NULL
  if(seasonality_on == 1 & !is.data.frame(init_EIR)){
    odin_det <- system.file("odin", "odin_model_stripped_seasonal.R", package = "sifter")
    det_model <- odin::odin(odin_det)
  } else if(seasonality_on == 0 & is.data.frame(init_EIR)){
    odin_det <- system.file("odin", "odin_model_stripped_matched.R", package = "sifter")
    det_model <- odin::odin(odin_det)
  } else if(seasonality_on==1 & is.data.frame(init_EIR)){
    # print('A seasonal, piecewise historical initialisation is not yet available.')
    # print('Setting a seasonal iniatilisation with the last EIR value provided.')
    odin_det <- system.file("odin", "odin_model_stripped_piecewise_seas.R", package = "sifter")
    det_model <- odin::odin(odin_det)
    # init_EIR = init_EIR$EIR[nrow(init_EIR)]
  }


  ## Load stochastic model in odin.dust
  # print('about to load stochastic model')
  ##Switch between EIR and mosquito emergence models
  stoch_file <- ifelse(stoch_param=='betaa','odinmodelmatchedstoch_mozemerg.R','odinmodelmatchedstoch.R')
  odin_stoch <- system.file("odin", stoch_file, package = "sifter")
  model <- odin.dust::odin_dust(odin_stoch)
  # print('loaded stochastic model')
  # print(model$public_methods$has_openmp())
  if(!model$public_methods$has_openmp()) warning('openmp must be enabled to run particle filter in parallel')

  ## Set initial state based on a user-given equilibrium EIR
  init_state <- initialise(init_EIR=init_EIR,mpl=mpl_pf,det_model=det_model)

  ### Set pmcmc parameters
  init_betaa <- mcstate::pmcmc_parameter("init_betaa", init_state$betaa_eq, min = 0,
                                         prior = function(p) dgamma(p, shape = 0.64, rate = 0.057, log = TRUE))
  volatility <- mcstate::pmcmc_parameter("volatility", rgamma(1,shape = 3.4, rate = 3.1), min = 0,
                                         prior = function(p) dgamma(p, shape = 3.4, rate = 3.1, log = TRUE))

  pars = list(init_betaa = init_betaa, volatility = volatility) ## Put pmcmc parameters into a list


  mcmc_pars <- mcstate::pmcmc_parameters$new(pars,
                                             proposal_matrix,
                                             transform = transform(init_state)) ## Calls transformation function based on pmcmc parameters

  n_threads <- dust::dust_openmp_threads(n_threads, action = "fix")
  if(comparison=='u5'){
    ##Output from particle filter
    ##    run: output used for likelihood calculation
    ##    state: output used for visualization
    index <- function(info) {
      list(run = c(prev = info$index$prev),
           state = c(prev_05 = info$index$prev,
                     EIR = info$index$EIR_out,
                     betaa = info$index$betaa_out,
                     clininc_all = info$index$inc,
                     prev_all = info$index$prevall,
                     clininc_05 = info$index$inc05,
                     Dout = info$index$Dout,
                     Aout = info$index$Aout,
                     Uout = info$index$Uout,
                     p_det_out = info$index$p_det_out,
                     phi_out = info$index$phi_out,
                     b_out = info$index$b_out,
                     spz_rate = info$index$spz_rate))
    }
    compare_funct <- compare_u5
 }
  else if(comparison=='pgmg'){
    ##Output from particle filter
    ##    run: output used for likelihood calculation
    ##    state: output used for visualization
    index <- function(info) {
      list(run = c(prev_pg = info$index$prev_preg_pg,
                   prev_mg = info$index$prev_preg_mg),
           state = c(prev_05 = info$index$prev,
                     prev_pg = info$index$prev_preg_pg,
                     prev_mg = info$index$prev_preg_mg,
                     EIR = info$index$EIR_out,
                     betaa = info$index$betaa_out,
                     clininc_all = info$index$inc,
                     prev_all = info$index$prevall,
                     clininc_05 = info$index$inc05,
                     Dout = info$index$Dout,
                     Aout = info$index$Aout,
                     Uout = info$index$Uout,
                     p_det_out = info$index$p_det_out,
                     phi_out = info$index$phi_out,
                     b_out = info$index$b_out,
                     spz_rate = info$index$spz_rate))
    }
    compare_funct <- compare_pgmg

  }
  else if(comparison=='pgsg'){
    index <- function(info) {
      list(run = c(prev_pg = info$index$prev_preg_pg,
                   prev_mg = info$index$prev_preg_sg),
           state = c(prev_05 = info$index$prev,
                     prev_pg = info$index$prev_preg_pg,
                     prev_sg = info$index$prev_preg_sg,
                     EIR = info$index$EIR_out,
                     betaa = info$index$betaa_out,
                     clininc_all = info$index$inc,
                     prev_all = info$index$prevall,
                     clininc_05 = info$index$inc05,
                     Dout = info$index$Dout,
                     Aout = info$index$Aout,
                     Uout = info$index$Uout,
                     p_det_out = info$index$p_det_out,
                     phi_out = info$index$phi_out,
                     b_out = info$index$b_out,
                     spz_rate = info$index$spz_rate))
    }
    compare_funct <- compare_pgmg
  }

  ##Tune particles
  if(particle_tune){
    control_tune <- mcstate::pmcmc_control(
      n_steps=100,
      save_state = FALSE,
      save_trajectories = FALSE,
      progress = TRUE,
      n_chains = n_chains, #TO DO: Make parameter to easily change
      n_workers = n_workers, #TO DO: Make parameter to easily change
      n_threads_total = n_threads,
      rerun_every = 1,
      rerun_random = FALSE)

    init_state$fixed_vol <- 1
    init_state$fixed_betaa <- init_state$betaa_eq

    min <- 10
    max <- 200
    test <- union(min * 2**(seq(0, floor(log2(max / min)))), max)
    found_good <- FALSE
    id <- 0
    target_variance <- 1

    while (!found_good && (id + 1) < length(test)) {
      id <- id + 1
      pf_tune <- mcstate::particle_filter$new(data, model, n_particles=test[id], compare_funct,
                                                    index = index,
                                                    stochastic_schedule = stochastic_schedule,
                                                    ode_control = dust::dust_ode_control(max_steps = max_steps, atol = atol, rtol = rtol),
                                                    n_threads = n_threads)
      pmcmc_run <- mcstate::pmcmc(mcmc_pars, pf_tune, control = control_tune)

      var_loglik <- stats::var(pmcmc_run$probabilities[,'log_likelihood'])
      print(pmcmc_run$probabilities)
      print(pmcmc_run$probabilities[,'log_likelihood'])
      print(var_loglik)
      if (is.na(var_loglik)) var_loglik <- 0

      message(
        date(), " ", test[id], " particles, loglikelihod variance: ",
        var_loglik
      )

      if (var_loglik < target_variance) {
        ## choose smallest var-loglikelihood < target_variance
        found_good <- TRUE
      }
    }
    if (!found_good) id <- length(test) #Take largest number of particles if still not hitting variance target
    n_particles <- test[id]
  }

  set.seed(seed) #To reproduce pMCMC results

  ### Set particle filter
  # print('about to set up particle filter')
  # print('set up particle filter')
  pf <- mcstate::particle_filter$new(data, model, n_particles, compare_funct,
                                     index = index, seed = seed,
                                     stochastic_schedule = stochastic_schedule,
                                     ode_control = dust::dust_ode_control(max_steps = max_steps, atol = atol, rtol = rtol),
                                     n_threads = n_threads)

  # print('about to set up pmcmc control')
  ### Set pmcmc control
  control <- mcstate::pmcmc_control(
    n_steps,
    save_state = TRUE,
    save_trajectories = TRUE,
    progress = TRUE,
    n_chains = n_chains, #TO DO: Make parameter to easily change
    n_workers = n_workers, #TO DO: Make parameter to easily change
    n_threads_total = n_threads,
    rerun_every = 50, #Re-runs particle filter about every 50 steps (random distribution, mean=50)
    rerun_random = TRUE)
  # print('set up pmcmc control')

  # print('parameters set')
  # print('starting pmcmc run')
  ### Run pMCMC
  start.time <- Sys.time()
  pmcmc_run <- mcstate::pmcmc(mcmc_pars, pf, control = control)
  run_time <- difftime(Sys.time(),start.time,units = 'secs')
  print(run_time)

  # if(n_chains > 1) pmcmc_run <- mcstate::pmcmc_combine(pmcmc_run)

  pars <- pmcmc_run$pars
  probs <- pmcmc_run$probabilities
  mcmc <- coda::as.mcmc(cbind(probs, pars))

  ##Save seasonality equilibrium trajectories if checking equilibrium
  seas_pretime <- NULL
  if(seasonality_on==1 & seasonality_check==1){
    print('Saving seasonality equilibrium trajectories')
    # Create list of seasonality trajectories for each set of sampled parameters in the posterior
    seas_pretime <- parallel::mclapply(1:nrow(pars), function(x) check_seasonality(theta=pars[x,],mpl_pf=mpl_pf,det_model=det_model))
  }
  to_return <- list(threads = n_threads,
                    particles = n_particles,
                    run_time = run_time,
                    mcmc = as.data.frame(mcmc),
                    pars = as.data.frame(pars),
                    probs = as.data.frame(probs),
                    times = pmcmc_run$trajectories$time,
                    history = pmcmc_run$trajectories$state,
                    seas_history = seas_pretime)

  return(to_return)
}
