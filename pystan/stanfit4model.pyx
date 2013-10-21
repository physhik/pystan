# distutils: language = c++
#-----------------------------------------------------------------------------
# Copyright (c) 2013, Allen B. Riddell
#
# This file is licensed under Version 3.0 of the GNU General Public
# License. See LICENSE for a text of the license.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# THIS IS A TEMPLATE, not a proper Cython .pyx file
#
# A template variable $model_cppname needs to be substituted before
# compilation.
#
# $model_cppname.hpp should be in the same directory as this
# file (after substitutions have been made).
#
#-----------------------------------------------------------------------------

# cython imports
from libcpp cimport bool
from libcpp.map cimport map
from libcpp.pair cimport pair
from libcpp.string cimport string
from libcpp.vector cimport vector

from cython.operator cimport dereference as deref

from pystan.io cimport py_var_context, var_context
from pystan.stan_fit cimport stan_fit, PyStanArgs, PyStanHolder

# python imports
from collections import OrderedDict
import logging

import numpy as np

import pystan.misc
import pystan.plots
from pystan._compat import PY2, string_types
from pystan.constants import sampling_algo_t, optim_algo_t, sampling_metric_t, stan_args_method_t

cdef extern from "boost/random/additive_combine.hpp" namespace "boost::random":
    cdef cppclass additive_combine_engine[T, U]:
        pass
    ctypedef additive_combine_engine ecuyer1988

cdef extern from "$model_cppname.hpp" namespace "${model_cppname}_namespace":
    cdef cppclass $model_cppname:
        $model_cppname(var_context& context) except +

# NOTE: Methods that aren't intended for public use are prefixed by '_'. For
# example, _update_param_names_oi probably shouldn't be called unless you know
# something about the state of the C++ class instance wrapped by the class.

cdef dict _dict_from_pystanholder(PyStanHolder* holder):
    r = {}
    r['num_failed'] = holder.num_failed
    r['test_grad'] = holder.test_grad
    r['inits'] = holder.inits
    r['par'] = holder.par
    r['value'] = holder.value
    chains = [np.asarray(ch) for ch in holder.chains]
    chain_names = [n.decode('utf-8') for n in holder.chain_names]
    r['chains'] = OrderedDict(zip(chain_names, chains))
    r['args'] = _dict_from_pystanargs(&holder.args)
    r['mean_pars'] = holder.mean_pars
    r['mean_lp__'] = holder.mean_lp__
    cdef bytes adaptation_info_bytes = holder.adaptation_info
    r['adapation_info'] = adaptation_info_bytes.decode('utf-8')
    r['sampler_params'] = holder.sampler_params
    r['sampler_param_names'] = [n.decode('utf-8') \
                                for n in holder.sampler_param_names]
    return r


cdef dict _dict_from_pystanargs(PyStanArgs* args):
    d = dict()
    ctrl_d = dict()
    d['random_seed'] = str(args.random_seed)
    d['chain_id'] = args.chain_id
    d['init'] = args.init
    # FIXME: yet to be implemented: d['init_list'] = args.init_list
    d['init_radius'] = args.init_radius
    d['append_samples'] = args.append_samples
    if args.sample_file_flag:
        d['sample_file'] = args.sample_file
    if args.diagnostic_file_flag:
        d['diagnostic_file'] = args.diagnostic_file

    method = stan_args_method_t(args.method)
    if method == stan_args_method_t.SAMPLING:
        d["method"] = "sampling"
        d["iter"] = args.ctrl.sampling.iter
        d["warmup"] = args.ctrl.sampling.warmup
        d["thin"] = args.ctrl.sampling.thin
        d["refresh"] = args.ctrl.sampling.refresh
        d["test_grad"] = False
        ctrl_d["adapt_engaged"] = args.ctrl.sampling.adapt_engaged
        ctrl_d["adapt_gamma"] = args.ctrl.sampling.adapt_gamma
        ctrl_d["adapt_delta"] = args.ctrl.sampling.adapt_delta
        ctrl_d["adapt_kappa"] = args.ctrl.sampling.adapt_kappa
        ctrl_d["adapt_t0"] = args.ctrl.sampling.adapt_t0
        algorithm = sampling_algo_t(args.ctrl.sampling.algorithm)
        if algorithm == sampling_algo_t.NUTS:
            metric = sampling_metric_t(args.ctrl.sampling.metric)
            if metric == sampling_metric_t.UNIT_E:
                ctrl_d["metric"] = "unit_e"
                d["sampler_t"] = "NUTS(unit_e)"
            elif metric == sampling_metric_t.DIAG_E:
                ctrl_d["metric"] = "diag_e"
                d["sampler_t"] = "NUTS(diag_e)"
            elif metric == sampling_metric_t.DENSE_E:
                ctrl_d["metric"] = "dense_e"
                d["sampler_t"] = "NUTS(dense_e)"
            ctrl_d["stepsize"] = args.ctrl.sampling.stepsize
            ctrl_d["stepsize_jitter"] = args.ctrl.sampling.stepsize_jitter
            ctrl_d["max_treedepth"] = args.ctrl.sampling.max_treedepth
        elif algorithm == sampling_algo_t.HMC:
            ctrl_d["int_time"] = args.ctrl.sampling.int_time
            d["sampler_t"] = "HMC"
        elif algorithm == sampling_algo_t.Metropolis:
            d["sampler_t"] = "Metropolis"

        d["control"] = ctrl_d
    elif method == stan_args_method_t.OPTIM:
        d["method"] = "optim"
        d["iter"] = args.ctrl.optim.iter
        d["refresh"] = args.ctrl.optim.refresh
        d["save_iterations"] = args.ctrl.optim.save_iterations
        algorithm = optim_algo_t(args.ctrl.optim.algorithm)
        if algorithm == optim_algo_t.Newton:
            d["algorithm"] = "Newton"
            pass
        elif algorithm == optim_algo_t.Nesterov:
            d["algorithm"] = "Nesterov"
            d["stepsize"] = args.ctrl.optim.stepsize
        elif algorithm == optim_algo_t.BFGS:
            d["algorithm"] = "BFGS"
            d["init_alpha"] = args.ctrl.optim.init_alpha
            d["tol_obj"] = args.ctrl.optim.tol_obj
            d["tol_grad"] = args.ctrl.optim.tol_grad
            d["tol_param"] = args.ctrl.optim.tol_param
    elif method == stan_args_method_t.TEST_GRADIENT:
        d["method"] = "test_grad"
        d["test_grad"] = True
    return d


cdef void _set_pystanargs_from_dict(PyStanArgs* p, dict args):
    """Insert values in dictionary `args` into `p`"""
    # _call_sampler requires a specially crafted dictionary of arguments
    # intended for the c++ function sampler_command(...) in stan_fit.hpp
    # If the dictionary doesn't contain the correct keys (arguments),
    # the function will raise a KeyError exception (as it should!).
    p.random_seed = <unsigned int> args.get('random_seed', 0)
    p.chain_id = <unsigned int> args['chain_id']
    p.init = args['init']
    # TODO: p.init_vars_r = ...
    # TODO: p.init_vars_i = ...
    p.init_radius = args['init_radius']
    p.sample_file = args['sample_file']
    p.append_samples = args['append_samples']
    p.sample_file_flag = args['sample_file_flag']
    p.method = args['method'].value
    p.sample_file = args['diagnostic_file']
    p.diagnostic_file_flag = args['diagnostic_file_flag']
    if args['method'] == stan_args_method_t.SAMPLING:
        p.ctrl.sampling.iter = args['ctrl']['sampling']['iter']
        p.ctrl.sampling.refresh = args['ctrl']['sampling']['refresh']
        p.ctrl.sampling.algorithm = args['ctrl']['sampling']['algorithm'].value
        p.ctrl.sampling.warmup = args['ctrl']['sampling']['warmup']
        p.ctrl.sampling.thin = args['ctrl']['sampling']['thin']
        p.ctrl.sampling.save_warmup = args['ctrl']['sampling']['save_warmup'] 
        p.ctrl.sampling.iter_save = args['ctrl']['sampling']['iter_save']
        p.ctrl.sampling.iter_save_wo_warmup = args['ctrl']['sampling']['iter_save_wo_warmup']
        p.ctrl.sampling.adapt_engaged = args['ctrl']['sampling']['adapt_engaged']
        p.ctrl.sampling.adapt_gamma = args['ctrl']['sampling']['adapt_gamma']
        p.ctrl.sampling.adapt_delta = args['ctrl']['sampling']['adapt_delta']
        p.ctrl.sampling.adapt_kappa = args['ctrl']['sampling']['adapt_kappa']
        p.ctrl.sampling.adapt_t0 = args['ctrl']['sampling']['adapt_t0']
        p.ctrl.sampling.metric = args['ctrl']['sampling']['metric'].value
        p.ctrl.sampling.stepsize = args['ctrl']['sampling']['stepsize']
        p.ctrl.sampling.stepsize_jitter = args['ctrl']['sampling']['stepsize_jitter']
        p.ctrl.sampling.max_treedepth = args['ctrl']['sampling']['max_treedepth']
        p.ctrl.sampling.int_time = args['ctrl']['sampling']['int_time']
    elif args['method'] == stan_args_method_t.OPTIM:
        p.ctrl.optim.iter = args['ctrl']['optim']['iter']
        p.ctrl.optim.refresh = args['ctrl']['optim']['refresh']
        p.ctrl.optim.algorithm = args['ctrl']['optim']['algorithm'].value
        p.ctrl.optim.save_iterations = args['save_iterations']
        p.ctrl.optim.stepsize = args['ctrl']['optim']['stepsize']
        p.ctrl.optim.init_alpha = args['ctrl']['optim']['init_alpha']
        p.ctrl.optim.tol_obj = args['ctrl']['optim']['tol_obj']
        p.ctrl.optim.tol_grad = args['ctrl']['optim']['tol_grad']
        p.ctrl.optim.tol_param = args['ctrl']['optim']['tol_param']


cdef class StanFit4$model_cppname:
    """Holder for results obtained from running a Stan model with data

    Attributes
    ----------
    sim : dict
        Holder for runs. Stores samples in sim['samples']
    data : dict
        Data used to fit model.

    Note
    ----
    The only unexpected difference between PyStan and RStan is this: where RStan
    stores samples for a parameter directly in, say, fit@sim$samples[[1]]$theta,
    in PyStan they are in fit.sim['samples'][0]['chains']['theta'].

    The difference is due to Python lacking a dictionary structure that can also
    have attributes.

    """

    cdef stan_fit[$model_cppname, ecuyer1988] *thisptr

    # attributes populated by methods of StanModel
    cdef public dict data
    cdef public dict sim
    cdef public model_name
    cdef public model_pars
    cdef public par_dims
    cdef public mode
    cdef public inits
    cdef public stan_args
    cdef public stanmodel
    cdef public date

    def __cinit__(self, dict data_r, dict data_i):
        # NB: dictionary keys must be byte strings

        cdef map[string, pair[vector[double], vector[size_t]]] vars_r
        cdef map[string, pair[vector[int], vector[size_t]]] vars_i

        # The dimension for a single value is an empty vector. A list of
        # values is indicated by an entry with the number of values.
        # The dimensions of an array are indicated as one would expect.
        #
        # note, array.flat yields values in C-contiguous style, with the
        # last index varying the fastest. So the transpose is taken
        # so that the ordering matches that used by stan.
        for key in data_i:
            assert isinstance(key, bytes), "Variable name must be bytes."
            val = (data_i[key].T.flat, data_i[key].shape)
            vars_i[key] = val
        for key in data_r:
            assert isinstance(key, bytes), "Variable name must be bytes."
            val = (data_r[key].T.flat, data_r[key].shape)
            vars_r[key] = val

        self.thisptr = new stan_fit[$model_cppname, ecuyer1988](vars_r, vars_i)
        if not self.thisptr:
            raise MemoryError("Couldn't allocate space for stan_fit.")

    def __dealloc__(self):
        del self.thisptr

    # public methods

    def plot(self, pars=None):
        return pystan.plots.traceplot(self, pars)

    def traceplot(self, pars=None):
        # FIXME: for now plot and traceplot do the same thing
        return pystan.plots.traceplot(self, pars)

    def extract(self, pars=None, permuted=True, inc_warmup=False):
        """Extract samples in different forms for different parameters.

        Parameters
        ----------
        pars : sequence of str
            names of parameters (including other quantities)
        permuted : bool
            If True, returned samples are permuted. All chains are merged and
            warmup samples are discarded.
        inc_warmup : bool
           If True, warmup samples are kept; otherwise they are discarded. If
           `permuted` is True, `inc_warmup` is ignored.

        Returns
        -------
        samples : dict or array
        If `permuted` is True, return dictionary with samples for each
        parameter (or other quantity) named in `pars`.

        If `permuted` is False, an array is returned. The first dimension of
        the array is for the iterations; the second for the number of chains;
        the third for the parameters. Vectors and arrays are expanded to one
        parameter (a scalar) per cell, with names indicating the third dimension.

        """
        if self.mode == 1:
            msg = "Stan model {} is of mode 'test_grad';\n" \
                "sampling is not conducted."
            raise AttributeError(msg.format(self.model_name))
        elif self.mode == 2 or self.sim.get('samples') is None:
            msg = "Stan model {} does not contain samples."
            raise AttributeError(msg.format(self.model_name))
        if inc_warmup is True and permuted is True:
            logging.warn("`inc_warmup` ignored when `permuted` is True.")

        if pars is None:
            pars = self.sim['pars_oi']
        elif isinstance(pars, string_types):
            pars = [pars]

        allpars = self.sim['pars_oi'] + self.sim['fnames_oi']
        pystan.misc._check_pars(allpars, pars)

        tidx = pystan.misc._pars_total_indexes(self.sim['pars_oi'],
                                               self.sim['dims_oi'],
                                               self.sim['fnames_oi'],
                                               pars)

        n_kept = [s-w for s, w in zip(self.sim['n_save'], self.sim['warmup2'])]

        if permuted:
            extracted = OrderedDict()
            for par in pars:
                sss = [pystan.misc._get_kept_samples(p, self.sim)
                       for p in tidx[par]]
                s = {par: np.column_stack(sss)}
                extracted.update(s)
                par_idx = self.sim['pars_oi'].index(par)
                par_dim = self.sim['dims_oi'][par_idx]
                # scalars have dim [], otherwise as one would expect
                par_dim = [1] if par_dim == [] else par_dim
                newdim = [sum(n_kept)] + par_dim
                # order='F' means column-major order
                extracted[par] = extracted[par].reshape(newdim, order='F')
                # squeeze dim, e.g., (4000,1) into (4000,)
                extracted[par] = np.squeeze(extracted[par])
        else:
            extracted = None
            for n in range(len(self.sim['fnames_oi'])):
                chains = pystan.misc._get_samples(n, self.sim, inc_warmup)
                n_save = self.sim['n_save'][0]
                if not inc_warmup:
                    n_save = n_save - self.sim['warmup2'][0]
                samples = np.array(chains).T
                if extracted is None:
                    extracted = samples[:, :, np.newaxis]
                else:
                    extracted = np.dstack([extracted, samples])
        return extracted

    def __unicode__(self):
        # for Python 2.x
        return pystan.misc._print_stanfit(self)

    def __str__(self):
        s = pystan.misc._print_stanfit(self)
        return s.encode('utf-8') if PY2 else s

    def summary(self):
        return pystan.misc._summary(self)

    def log_prob(self, upars, adjust_transform=True, gradient=False):
        """
        Expose the log_prob of the model to stan_fit so user can call
        this function.

        Parameters
        ----------
        upar :
            The real parameters on the unconstrained space.
        adjust_transform : bool
            Whether we add the term due to the transform from constrained
            space to unconstrained space implicitly done in Stan.

        Note
        ----
        In Stan, the parameters need be defined with their supports. For
        example, for a variance parameter, we must define it on the positive
        real line. But inside Stan's sampler, all parameters defined on the
        constrained space are transformed to unconstrained space, so the log
        density function need be adjusted (i.e., adding the log of the absolute
        value of the Jacobian determinant).  With the transformation, Stan's
        samplers work on the unconstrained space and once a new iteration is
        drawn, Stan transforms the parameters back to their supports. All the
        transformation are done inside Stan without interference from the users.
        However, when using the log density function for a model exposed to
        Python, we need to be careful.  For example, if we are interested in
        finding the mode of parameters on the constrained space, we then do not
        need the adjustment.  For this reason, there is an argument named
        `adjust_transform` for functions `log_prob` and `grad_log_prob`.

        """
        # gradient is ignored for now. Call grad_log_prob to get the gradient.
        cdef vector[double] par_r = np.asarray(upars).flat
        return self.thisptr.log_prob(par_r, adjust_transform, gradient)

    # FIXME: adding this creates a strange Cython error
    # redefinition of ‘PyObject* __pyx_convert_vector_to_py_double(const std::vector<double>&)
    #
    # def grad_log_prob(self, upars, adjust_transform=True):
    #     """
    #     Expose the grad_log_prob of the model to stan_fit so user
    #     can call this function.

    #     Parameters
    #     ----------
    #     upar :
    #         The real parameters on the unconstrained space.
    #     adjust_transform : bool
    #         Whether we add the term due to the transform from constrained
    #         space to unconstrained space implicitly done in Stan.
    #     """
    #     cdef vector[double] par_r = upars
    #     return self.thisptr.grad_log_prob(par_r, adjust_transform)
    def grad_log_prob(self, upars, adjust_transform=True):
        raise NotImplementedError("grad_log_prob is not yet implemented")

    # "private" Python methods

    def _update_param_oi(self, pars):
        cdef vector[string] pars_ = pars
        cdef int ret = self.thisptr.update_param_oi(pars_)
        return ret

    def _get_param_names(self):
        cdef vector[string] param_names_bytes = self.thisptr.param_names()
        param_names = [n.decode('utf-8') for n in param_names_bytes]
        return param_names

    def _get_param_fnames_oi(self):
        cdef vector[string] param_fnames_bytes = self.thisptr.param_fnames_oi()
        param_fnames = [n.decode('utf-8') for n in param_fnames_bytes]
        return param_fnames

    def _get_param_names_oi(self):
        cdef vector[string] param_names_bytes = self.thisptr.param_names_oi()
        param_names = [n.decode('utf-8') for n in param_names_bytes]
        return param_names

    def _get_param_dims(self):
        cdef vector[vector[uint]] dims = self.thisptr.param_dims()
        dims_ = dims
        return dims_

    def _call_sampler(self, dict args):
        # For parallel processing args and return values need to be picklable
        cdef PyStanHolder *holderptr = new PyStanHolder()
        cdef PyStanArgs *argsptr = new PyStanArgs()
        if not holderptr:
            raise MemoryError("Couldn't allocate space for PyStanHolder.")
        if not argsptr:
            raise MemoryError("Couldn't allocate space for PyStanArgs.")

        _set_pystanargs_from_dict(argsptr, args)
        ret = self.thisptr.call_sampler(deref(argsptr), deref(holderptr))
        holder_dict = _dict_from_pystanholder(holderptr)
        del holderptr
        del argsptr
        return ret, holder_dict
