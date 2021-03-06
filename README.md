# ParameterizedFunctions.jl

[![Join the chat at https://gitter.im/JuliaDiffEq/Lobby](https://badges.gitter.im/JuliaDiffEq/Lobby.svg)](https://gitter.im/JuliaDiffEq/Lobby?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)
[![Travis](https://travis-ci.org/JuliaDiffEq/ParameterizedFunctions.jl.svg?branch=master)](https://travis-ci.org/JuliaDiffEq/ParameterizedFunctions.jl) [![AppVeyor](https://ci.appveyor.com/api/projects/status/k6b7d86ddbas1ajk?svg=true)](https://ci.appveyor.com/project/ChrisRackauckas/parameterizedfunctions-jl)
[![codecov](https://codecov.io/gh/JuliaDiffEq/ParameterizedFunctions.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaDiffEq/ParameterizedFunctions.jl)

ParameterizedFunctions.jl is a component of the JuliaDiffEq ecosystem which allows
for parameters to be explicitly present within functions. The interface which
ParameterizedFunctions describes allows for functionality which requires parameters,
such as parameter sensitivity analysis and parameter estimation, to be added to
the differential equation solvers of [DifferentialEquations.jl](https://github.com/JuliaDiffEq/DifferentialEquations.jl).
While the interface itself is of importance to ecosystem developers,
ParameterizedFunctions.jl provides user-facing macros which make a
`ParameterizedFunction` easy to define, and automatically
include optimizations like explicit Jacobian functions and explicit inverse Jacobian
functions for the differential equation solvers to take advantage of. The result
is an easy to use API which allows for more functionality and more performance
optimizations than could traditionally be offered.

## The Basic Idea

`ParameterizedFunction` is a type which can be used in various JuliaDiffEq solvers where
the parameters must be accessible by the solver function. These use call overloading
generate a type which acts like a function `f(t,u,du)` but has access to many more
features. For example, a `ParameterizedFunction` can contain a function for the Jacobian
or Inverse Jacobian. If such functions exist, the solvers can use them to increase
the speed of computations. If they don't exist, the solvers will ignore them. Since
`ParameterizedFunction` is a subtype of `Function`, these can be used anywhere that
a function can be used, just with the extra functionality ignored.

## Basic Usage via Macros

### ODEs

A helper macro is provided to make it easier to define a `ParameterizedFunction`.
For example, to define the previous `LotkaVolterra`, you can use the following command:

```julia
f = @ode_def LotkaVolterra begin
  dx = a*x - b*x*y
  dy = -c*y + d*x*y
end a=>1.5 b=>1 c=3 d=1
```

Note that the syntax  for parameters here is that `=>` will
put these inside the parameter type, while `=` will inline the number (i.e. replace
each instance of `c` with `3`). Inlining slightly decreases the function cost and
so is preferred in any case where you know that the parameter will always be constant.
This will silently create the `LotkaVolterra` type and thus `g=LotkaVolterra(a=1.0,b=2.0)`
will create a different function where `a=1.0` and `b=2.0`. However, at any time
the parameters of `f` can be changed by using `f.a =` or `f.b = `.

The macro also defines the Jacobian `f'`. This is defined as an in-place Jacobian `f(Val{:jac},t,u,J)`.
This is calculated using SymEngine.jl automatically, so it's no effort on your part.
The symbolic inverse of the Jacobian is also computed, and an in-place function
for this is available as well as `f(Val{:invjac},t,u,iJ)`. If the Jacobians cannot be
computed, a warning is thrown and only the function itself is usable. The functions
`jac_exists(f)` and `invjac_exists(f)` can be used to see whether the Jacobian
and the function for its inverse exist.

#### Extra Options

In most cases the `@ode_def` macro should be sufficient. This is because by default
the macro will simply calculate each function symbolically, and if it can't it
will simply throw a warning and move on. However, in extreme cases the symbolic
calculations may take a long time, in which case it is necessary to turn them
off. To do this, use the `ode_def_opts` function. The `@ode_def` macro simply defines the specifiable options:

```julia
opts = Dict{Symbol,Bool}(
      :build_tgrad => true,
      :build_jac => true,
      :build_expjac => false,
      :build_invjac => true,
      :build_invW => true,
      :build_invW_t => true,
      :build_hes => true,
      :build_invhes => true,
      :build_dpfuncs => true)
```

and calls the function `ode_def_opts(name::Symbol,opts,ex::Expr,params)`. Note that
params is an iterator holding expressions for the parameters.

#### Extra Macros

Instead of using `ode_def_opts` directly, one can use one of the following macros
to be more specific about what to not calculate. In increasing order of calculations:

```julia
@ode_def_bare
@ode_def_noinvjac
@ode_def_noinvhes
@ode_def_nohes
```

Also, the Rosenbrock-W calculations assume a mass matrix `M` is `I` by default.
They solve for the explicit `(M - γJ)^(-1)`  and `(M/γ - J)^(-1)` which in the
Rosenbrock numerical schemes has to computed at each timestep.  To choose a
different mass matrix, use

```julia
@ode_def_mm
@ode_def_noinvjac_mm
@ode_def_noinvhes_mm
@ode_def_nohes_mm
```

where the argument before the expression is the mass matrix, like:

```julia
M = [2 1
     1 2]
f_m = @ode_def_noinvhes_mm LotkaVolterraMassMatrix M begin
  dx = a*x - b*x*y
  dy = -c*y + d*x*y
end a=>1.5 b=>1 c=>3 d=1
```

Note that for this the mass matrix must be constant.

### Finite Element PDEs

Similar macros for finite element method definitions also exist. For the finite
element solvers, the definitions use `x[:,1]` instead of `x` and `x[:,2]` instead of `y`.
To more easily define systems of equations for finite element solvers, we can
use the `@fem_def` macro. The first argument is the function signature. This
is required in order to tell the solver linearity. Other than that, the macro
usage is similar to before. For example,

```julia
l = @fem_def (t,x,u) BirthDeath begin
  du = 1-x*α*u
  dv = 1-y*v
end α=0.5
```

defines a system of equations

```julia
l = (t,x,u)  -> [1-.5*x[:,1]*u[:,1]   1-x[:,2]*u[:,2]]
```

which is in the form for the FEM solver.

## The ParameterizedFunction Interface

The ParameterizedFunction interface is as follows:

- ParameterizedFunction is a type which is a subtype of Function
- The type must hold the parameters.
- Hessians, Inverse Jacobians, Inverse Hessians, explicit parameter functions,
  parameter derivatives, and parameter Jacobians.
- The standard call `(p::TypeName)(t,u,du)` must be overloaded for the function
  calculation. All other functions are optional.

Solvers can interface with ParameterizedFunctions as follows:

```julia
f.a # accesses the parameter a
f(t,u,du) # Call the function
f(t,u,params,du) # Call the function to calculate with parameters params (vector)
f(Val{:tgrad},t,u,J) # Call the explicit t-gradient function
f(Val{:a},t,u,2.0,du) # Call the explicit parameter function with a=2.0
f(Val{:deriv},Val{:a},t,u,2.0,df) # Call the explicit parameter derivative function with a=2.0
f(Val{:paramjac},t,u,params,J) # Call the explicit parameter Jacobian function
f(Val{:jac},t,u,J) # Call the explicit Jacobian function
f(Val{:expjac},t,u,γ,J) # Call the explicit exponential Jacobian function exp(γJ)
f(Val{:invjac},t,u,iJ) # Call the explicit Inverse Jacobian function
f(Val{:invW},t,u,γ,iW) # Call the explicit inverse Rosenbrock-W function (M - γJ)^(-1)
f(Val{:invW_t},t,u,γ,iW) # Call the explicit transformed inverse Rosenbrock-W function (M/γ - J)^(-1)
f(Val{:hes},t,u,H) # Call the explicit Hessian function
f(Val{:invhes},t,u,iH) # Call the explicit Inverse Hessian function
```

To test for whether certain overloads exist, the following functions are provided
by traits in [DiffEqBase.jl](https://github.com/JuliaDiffEq/DiffEqBase.jl):

```julia
has_jac(f)
has_expjac(f)
has_invjac(f)
has_tgrad(f)
has_hes(f)
has_invhes(f)
has_invW(f)
has_invW_t(f)
has_paramjac(f)
has_paramderiv(f)
```

These are compile-time checks and thus the inappropriate branches will compile
way when a function (usually an ODE/SDE solver) is dispatched on `f`. It is
requested that solvers should only use the explicit functions when they exist
to help with performance.

## Manually Defining `ParameterizedFunction`s

It's recommended that for simple uses you use the macros. However, in many cases
the macros will not suffice, but you may still wish to provide Jacobians to the
solvers. This shows how to manually build a ParameterizedFunction to give to
a solver.

### Template

An example of explicitly defining a parameterized function is as follows. This serves
as a general template for doing so:

```julia
type  LotkaVolterra <: ParameterizedFunction
         a::Float64
         b::Float64
end
f = LotkaVolterra(0.0,0.0)
(p::LotkaVolterra)(t,u,du) = begin
         du[1] = p.a * u[1] - p.b * u[1]*u[2]
         du[2] = -3 * u[2] + u[1]*u[2]
end
```

### Explanation

Let's go step by step to see what this template does. The first part defines a
type:

```julia
type  LotkaVolterra <: ParameterizedFunction
         a::Float64
         b::Float64
end
```

The fields are the parameters for our function. Then we built the type:

```julia
f = LotkaVolterra(0.0,0.0)
```

We put in values for the parameters and told it that we will be defining each of
those functions. First we define the main overload. This is required even if none
of the other functions are provided. The function for the main overload is the
differential equation, so for the Lotka-Volterra equation:

```julia
(p::LotkaVolterra)(t,u,du) = begin
         du[1] = p.a * u[1] - p.b * u[1]*u[2]
         du[2] = -3 * u[2] + u[1]*u[2]
end
```

Note how we represented the parameters in the equation. If you did this and set
the booleans to false, the result is `f` is a `ParameterizedFunction`,
but `f(t,u,du)` acts like the function:

```julia
function f(t,u,du)
         du[1] = 0.0 * u[1] - 0.0 * u[1]*u[2]
         du[2] = -3 * u[2] + u[1]*u[2]
end
```

At anytime the function parameters can be accessed by the fields (`f.a`, `f.b`).

### Extra Functions

#### Jacobian Function

The Jacobian overload is provided by overloading in the following manner:

```julia
function (p::LotkaVolterra)(::Type{Val{:jac}},t,u,J)
  J[1,1] = p.a - p.b * u[2]
  J[1,2] = -(p.b) * u[1]
  J[2,1] = 1 * u[2]
  J[2,2] = -3 + u[1]
  nothing
end
```

#### Inverse Jacobian

The Inverse Jacobian overload is provided by overloading in the following manner:

```julia
function (p::LotkaVolterra)(::Type{Val{:invjac}},t,u,J)
  J[1,1] = (1 - (p.b * u[1] * u[2]) / ((p.a - p.b * u[2]) * (-3 + u[1] + (p.b * u[1] * u[2]) / (p.a - p.b * u[2])))) / (p.a - p.b * u[2])
  J[1,2] = (p.b * u[1]) / ((p.a - p.b * u[2]) * (-3 + u[1] + (p.b * u[1] * u[2]) / (p.a - p.b * u[2])))
  J[2,1] = -(u[2]) / ((p.a - p.b * u[2]) * (-3 + u[1] + (p.b * u[1] * u[2]) / (p.a - p.b * u[2])))
  J[2,2] = (-3 + u[1] + (p.b * u[1] * u[2]) / (p.a - p.b * u[2])) ^ -1
  nothing
end
```

#### Hessian and Inverse Hessian

These are the same as the Jacobians, except with value types `:hes` and `:invhes`.

#### Explicit Parameter Functions

For solvers which need to auto-differentiate parameters (local sensitivity analysis),
explicit parameter functions are required. For our example, we do the following:

```julia
function (p::LotkaVolterra)(::Type{Val{:a}},t,u,a,du)
  du[1] = a * u[1] - p.b * u[1] * u[2]
  du[2] = -3 * u[2] + 1 * u[1] * u[2]
  nothing
end
function (p::LotkaVolterra)(::Type{Val{:b}},t,u,b,du)
  du[1] = p.a * u[1] - b * u[1] * u[2]
  du[2] = -3 * u[2] + 1 * u[1] * u[2]
  nothing
end
```

#### Explicit Parameter Derivatives

For solvers which need parameters derivatives, specifying the functions can increase
performance. For our example, we allow the solvers to use the explicit derivatives
in the parameters `a` and `b` by:

```julia
function (p::LotkaVolterra)(::Type{Val{:deriv}},::Type{Val{:a}},t,u,a,du)
  du[1] = 1 * u[1]
  du[2] = 1 * 0
  nothing
end
function (p::LotkaVolterra)(::Type{Val{:deriv}},::Type{Val{:b}},t,u,b,du)
  du[1] = -(u[1]) * u[2]
  du[2] = 1 * 0
  nothing
end
```
