if has('nvim')
    "nvim is not supported currently
    finish
endif
" check whether this script is already loaded
if exists("g:loaded_vim_job_chain")
  finish
endif

let g:loaded_vim_job_chain = 1

