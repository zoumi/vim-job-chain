
"a dict of job chain:{node:JobChainNode,job_idx:int}
if !exists('g:chain_node_info_job_dict')
    let g:chain_node_info_job_dict = {}
endif

func! _comment()
" function close_cb(channel,job=v:null) should returns a bool
" 'next_node' will be execute only when all nodes in node_list and all jobs in
" job_list finished and all their close_cb returns true.
" when a chain node is finished, the finished_cb will be called 
" node in node_list is executed parallelly
" job in job_list is executed parallelly
Job{
    name:'',
    job_cmd:'', "must provided
    job_arg:'',
    pre_do:func,
    pre_do_args_list:[],
}

JobChainNode
{
    name:"",
    job_list:[Job;N],
    orphan_job_list:[Job;N],
    node_list:[JobChainNode;N],
    orphan_node_list:[JobChainNode;N],
    next_node:JobChainNode,
    finished_cb: func(node),

    "internal use
    _status:"", "run,fail,finish
    _job_status_list:["";N], 
    " only node in node_list has parent
    _parent_node:JobChainNode,
}
endfunc

func! s:try_finish_parent_node(node)
    let parent_node = a:node._parent_node
    while parent_node isnot v:null
        let status = vim_job_chain#get_chain_node_status(parent_node)
        if (status == 'finish')  && (parent_node._status != 'finish')
            let parent_node._status = 'finish'
            if has_key(parent_node,'finished_cb')
                call parent_node.finished_cb(parent_node)
            endif
            if parent_node.next_node isnot v:null
                call s:execute_chain_node(parent_node.next_node,a:node)
            endif
        endif
        let parent_node = parent_node._parent_node
    endwhile
endfunc

func! s:set_parent_node_failed(node)
    let parent_node = a:node._parent_node
    while parent_node isnot v:null
        if parent_node._status != 'fail'
            let parent_node._status = 'fail'
            if has_key(parent_node,'finished_cb')
                call parent_node.finished_cb(parent_node)
            endif
        endif
        let parent_node = parent_node._parent_node
    endwhile
endfunc

" orphan job's cb will not be wrapped
" because we don't care it's result
func! s:wrapped_job_cb(channel) 
    let raw_job = ch_getjob(a:channel)
    let j_i = job_info(raw_job)
    let j_id = join(j_i.cmd) . '#' . j_i.process
    let err_info = v:null
    if has_key(g:chain_node_info_job_dict, j_id)
        let node_info = g:chain_node_info_job_dict[j_id]
        let node = node_info['node']
        let job_idx = node_info['job_idx']
        let job = node.job_list[job_idx]
        let job_result = v:true
        if has_key(job.job_arg,'close_cb')
            let Cb = function(job.job_arg.close_cb)
            try
                let job_result = Cb(a:channel,job)
            catch /.*/
                let job_result = v:false
                let err_info = "close_cb error: " . v:exception . " in " . v:throwpoint
            endtry
        else
            let job_result = vim_job_chain#default_close_cb(a:channel,job)
        endif
        if job_result
            let node._job_status_list[job_idx] = 'finish' 
        else
            let node._job_status_list[job_idx] = 'fail' 
        endif
        let node_status = vim_job_chain#get_chain_node_status(node)
        if node_status == 'finish'
            " if has_key(node,'name')
                " echomsg 'node '. node.name . ' finished' 
                " if has_key(node,'_parent_node')
                            " \ && has_key(node._parent_node,'name')
                    " echomsg 'parent:' . node._parent_node.name
                " endif
            " endif

            let node._status = 'finish'
            if has_key(node,'finished_cb')
                try
                    call node.finished_cb(node)
                catch /.*/
                    let err_info = "finished_cb error: " . v:exception . " in " . v:throwpoint
                    " throw "finished_cb error: " . v:exception
                endtry
            endif
            if node.next_node isnot v:null
                " execute next node
                " next_node's parent is same as current node
                call s:execute_chain_node(node.next_node,node._parent_node)
            else
                "check if parent node can be finished
                call s:try_finish_parent_node(node)
            endif
        elseif node_status == 'fail'
            let node._status = 'fail'
            call s:set_parent_node_failed(node)
        endif
    else
        echoerr "Get un-recorded job:"
    endif
    call remove(g:chain_node_info_job_dict,j_id)
    if err_info isnot v:null
        throw err_info
    endif
endfunc

func! vim_job_chain#get_chain_node_status(node) abort
    "any job or node is failed then the node is fail
    "all job or node is finished then the node is finish
    "otherwise the node is run
    let j_fail = v:false
    let j_finish = v:true
    for s in a:node._job_status_list
        if s == 'fail'
            let j_fail = v:true
            break
        elseif s == 'run'
            let j_finish = v:false
        endif
    endfor

    for n in a:node.node_list
        if n._status == 'fail'
            let j_fail = v:true
            break
        elseif n._status == 'run'
            let j_finish = v:false
        endif
    endfor

    if j_fail
        return 'fail'
    elseif j_finish
        return 'finish'
    else 
        return 'run'
    endif
endfunc

func! s:pre_do(j,node)
    let err_info = v:null
    if has_key(a:j, 'pre_do')
        if has_key(a:j, 'pre_do_args_list')
            try 
                call(a:j.pre_do,a:j.pre_do_args_list)
            catch /.*/
                " throw "pre_do error: " . v:exception
                let err_info = "pre_do error: " . v:exception . " in " . v:throwpoint
            endtry
        else
            try 
                call a:j.pre_do()
            catch /.*/
                " echoerr a:j
                " throw "pre_do error: " . v:exception
                let err_info = "pre_do error: " . v:exception . " in " . v:throwpoint
            endtry
        endif
    endif
    if err_info isnot v:null
        throw err_info
    endif
endfunc

func! s:execute_chain_node(node,parent_node = v:null) abort
    if has_key(a:node,'orphan_job_list')
        for o_j in a:node.orphan_job_list
            call s:pre_do(o_j,a:node)
            call job_start(o_j.job_cmd,o_j.job_arg)
        endfor
    endif

    if has_key(a:node,'orphan_node')
        for o_n in a:node.orphan_node_list
            call s:execute_chain_node(o_n,v:null)
        endfor
    endif

    if !has_key(a:node, '_job_status_list')
        let a:node._job_status_list = []
    endif

    let a:node._parent_node = a:parent_node
    let a:node._status = 'run'

    if has_key(a:node,'job_list')
        let j_idx = 0
        for j in a:node.job_list
            call add(a:node._job_status_list,"run")
            let wrapped_j = deepcopy(j)
            let wrapped_j.job_arg.close_cb = function('s:wrapped_job_cb')
            call s:pre_do(wrapped_j, a:node)
            let j_o = job_start(wrapped_j.job_cmd,wrapped_j.job_arg)
            let j_i = job_info(j_o)
            if j_i.status != 'run'
                let a:node._job_status_list[j_idx] = 'fail'
                let channel =  job_getchannel(j_o)
                let std_err = ""
                if ch_status(channel, {'part': 'err'}) == 'buffered'
                    let std_err = ch_readraw(a:channel, {"part": "err"})
                endif
                echoerr "start job failed with exit code: " . string(j_i.exitval) . " err msg:" . channel
            else
                let j_id = join(j_i.cmd) . '#' . j_i.process
                " echomsg "create job " . j_id
                if has_key(g:chain_node_info_job_dict,j_id)
                    echoerr "duplicate job handle"
                else
                    let g:chain_node_info_job_dict[j_id] = {'node':a:node,'job_idx':j_idx}
                endif
            endif
            let j_idx += 1
        endfor
    else
        let a:node.job_list = []
    endif

    if has_key(a:node,'node_list')
        for n in a:node.node_list
            call s:execute_chain_node(n,a:node)
        endfor
    else
        let a:node.node_list = []
    endif

    if (len(a:node.node_list) == 0) 
                \ && (len(a:node.job_list)==0)
        let a:node._status = 'finish'
        if has_key(a:node,'finished_cb')
            call a:node.finished_cb(node)
        endif

        if a:node.next_node isnot v:null
            " execute next node
            " next_node's parent is same as current node
            call s:execute_chain_node(a:node.next_node,a:node._parent_node)
        else
            "check if parent node can be finished
            call s:try_finish_parent_node(a:node)
        endif
    endif

    "check is this node failed
    let node_status = vim_job_chain#get_chain_node_status(a:node)
    if node_status == 'fail'
        " all parent should be marked as 'fail'
        let parent_node = a:node._parent_node
        while parent_node isnot v:null
            if parent_node._status != 'fail'
                let parent_node._status = 'fail'
                if has_key(parent_node,'finished_cb')
                    call parent_node.finished_cb(parent_node)
                endif
            endif
            let parent_node = parent_node._parent_node
        endwhile
    endif
endfunc

func! vim_job_chain#execute_chain_node(node,parent_node = v:null) abort
    let node = deepcopy(a:node)
    let parent_node = deepcopy(a:parent_node)
    call s:execute_chain_node(node,parent_node)
    return node
endfunc

func! vim_job_chain#get_job_result(channel)
    let job = ch_getjob(a:channel)
    " echomsg job_status(job)
    let job_info = job_info(job)
    " echomsg  job_info
    "exit_code: ok:0 error: not 0
    let exit_code = job_info.exitval

    let std_err = ''
    if ch_status(a:channel, {'part': 'err'}) == 'buffered'
        let std_err = ch_readraw(a:channel, {"part": "err"})
    endif

    " echomsg ch_info(a:channel)
    let std_out = ''
    if ch_status(a:channel, {'part': 'out'}) == 'buffered'
        let std_out= ch_readraw(a:channel)
        " echomsg 'std_out:' . std_output
    endif
    return {'exit_code':exit_code,
                \ 'std_err':std_err,
                \ 'std_out':std_out}
endfunc

func! vim_job_chain#default_close_cb(channel,job)
    let job = ch_getjob(a:channel)
    let job_info = job_info(job)
    return job_info.exitval == 0
endfunc

func! vim_job_chain#simple_close_cb(channel,job)
    let job_re = vim_job_chain#get_job_result(a:channel)
    let job_name = get(a:job,'name','NoName')
    if job_re.exit_code == 0
        if job_re.std_out != ''
            echomsg job_name . ' std_out:' . job_re.std_out
        endif
        echomsg job_name . ' success.'
        return v:true
    else
        echoerr job_name . ' failed:' . job_re.std_err
    endif
    return v:false
endfunc

func! vim_job_chain#append_chain(node,next_node) abort
    let tmp_node = a:node
    while 1
        if tmp_node.next_node is v:null
            let tmp_node.next_node = a:next_node
            break
        else
            let tmp_node = tmp_node.next_node
        endif
    endwhile
    return a:node
endfunc

func! vim_job_chain#deepcopy_append_chain(node,next_node) abort
    let re_node = deepcopy(a:node)
    let tmp_node = re_node
    while 1
        if tmp_node.next_node is v:null
            let tmp_node.next_node = deepcopy(a:next_node)
            break
        else
            let tmp_node = tmp_node.next_node
        endif
    endwhile
    return re_node
endfunc

"can be nested [[job1,job2,[job3,job4]],job5]
"or a single job: job1 or [job1]
func! vim_job_chain#chain_with_jobs(node,jobs) abort
    let ch = vim_job_chain#build_from_jobs(a:jobs)
    call vim_job_chain#append_chain(a:node,ch)
    return a:node
endfunc

func! vim_job_chain#build_empty_node() abort
    return {'job_list': [], 'next_node': v:null}
endfunc

"can be nested [[job1,job2,[job3,job4]],job5]
"or a single job: job1 or [job1]
func! vim_job_chain#build_from_jobs(jobs) abort
    let re = vim_job_chain#build_empty_node()
    if type(a:jobs) != v:t_list
        call add(re.job_list,jobs)
        return re
    endif

    let got_child = v:false
    for e in a:jobs
        if type(e) == v:t_list
            if got_child == v:false
                let got_child = v:true
                call vim_job_chain#append_chain(re,
                            \ vim_job_chain#build_from_jobs(e))
            else
                echoerr 'got error job_list:' . string(e) . '. job list can not has multiple sub job list'
            endif
        else
            call add(re.job_list,e)
        endif
    endfor
    return re
endfunc

