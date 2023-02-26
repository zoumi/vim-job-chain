
"a dict of job:{node:JobChainNode,job_idx:int}
if !exists('g:chain_node_info_job_dict')
    let g:chain_node_info_job_dict = {}
endif

func! _comment()
" next_node will be execute only when all nodes in node_list and all jobs in
" job_list finished and all their close_cb returns true
" function close_cb(channel) should returns a bool
" when a chain node is finished, the finished_cb will be called 
" node in node_list is executed parallelly
" job in job_list is executed parallelly
Job{
    name:'',
    job_cmd:'', "must provided
    pre_do:func,
    pre_do_args_list:[],
    job_arg:''
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
    while parent_node != v:null
        let status = vim_job_chain#get_chain_node_status(parent_node)
        if (status == 'finish')  && (parent_node._status != 'finish')
            let parent_node._status = 'finish'
            if has_key(parent_node,'finished_cb')
                call parent_node.finished_cb(parent_node)
            endif
            if parent_node.next_node != v:null
                call s:execute_chain_node(parent_node.next_node,a:node)
            endif
        endif
        let parent_node = parent_node._parent_node
    endwhile
endfunc

func! s:set_parent_node_failed(node)
    let parent_node = a:node._parent_node
    while parent_node != v:null
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
                let job_result = Cb(a:channel)
            catch /.*/
                let job_result = v:false
                let err_info = "close_cb error: " . v:exception . " in " . v:throwpoint
            endtry
        else
            let job_result = vim_job_chain#default_close_cb(a:channel)
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
            if node.next_node != v:null
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
    if err_info != v:null
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
    if err_info != v:null
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
                echoerr "start job failed with exit code: " . string(j_i.exitval)
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

        if a:node.next_node != v:null
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
        while parent_node != v:null
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

func! vim_job_chain#default_close_cb(channel)
    let job = ch_getjob(a:channel)
    let job_info = job_info(job)
    return job_info.exitval == 0
endfunc

func! vim_job_chain#append_chain(node,next_node) abort
    let tmp_node = a:node
    while 1
        if tmp_node.next_node == v:null
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
        if tmp_node.next_node == v:null
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

func! s:test() abort
    func! s:job1_cb(channel)
        echomsg "job1_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job2_cb(channel)
        echomsg "job2_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job3_cb(channel)
        echomsg "job3_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job4_cb(channel)
        echomsg "job4_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job5_cb(channel)
        echomsg "job5_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job6_cb(channel)
        echomsg "job6_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job7_cb(channel)
        echomsg "job7_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job8_cb(channel)
        echomsg "job8_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job9_cb(channel)
        echomsg "job9_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job10_cb(channel)
        echomsg "job10_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job11_cb(channel)
        echomsg "job11_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job12_cb(channel)
        echomsg "job12_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job13_cb(channel)
        echomsg "job13_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job14_cb(channel)
        echomsg "job14_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job15_cb(channel)
        echomsg "job15_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job16_cb(channel)
        echomsg "job16_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job17_cb(channel)
        echomsg "job17_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job18_cb(channel)
        echomsg "job18_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job19_cb(channel)
        echomsg "job19_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job20_cb(channel)
        echomsg "job20_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job21_cb(channel)
        echomsg "job21_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job22_cb(channel)
        echomsg "job22_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job23_cb(channel)
        echomsg "job23_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job24_cb(channel)
        echomsg "job24_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc

    func! s:job25_cb(channel)
        echomsg "job25_cb" | return vim_job_chain#default_close_cb(a:channel)
    endfunc


    let job1 =  {'job_cmd':'git --help','job_arg':{'close_cb':'s:job1_cb','mode':'raw'}}
    let job2 =  {'job_cmd':'git --help','job_arg':{'close_cb':'s:job2_cb','mode':'raw'}}
    let job3 =  {'job_cmd':'git --help','job_arg':{'close_cb':'s:job3_cb','mode':'raw'}}
    let job4 =  {'job_cmd':'git --help','job_arg':{'close_cb':'s:job4_cb','mode':'raw'}}
    let job5 =  {'job_cmd':'git --help','job_arg':{'close_cb':'s:job5_cb','mode':'raw'}}
    let job6 =  {'job_cmd':'git --help','job_arg':{'close_cb':'s:job6_cb','mode':'raw'}}
    let job7 =  {'job_cmd':'git --help','job_arg':{'close_cb':'s:job7_cb','mode':'raw'}}
    let job8 =  {'job_cmd':'git --help','job_arg':{'close_cb':'s:job8_cb','mode':'raw'}}
    let job9 =  {'job_cmd':'git --help','job_arg':{'close_cb':'s:job9_cb','mode':'raw'}}
    let job10 = {'job_cmd':'git --help','job_arg':{'close_cb':'s:job10_cb','mode':'raw'}}
    let job11 = {'job_cmd':'git --help','job_arg':{'close_cb':'s:job11_cb','mode':'raw'}}
    let job12 = {'job_cmd':'git --help','job_arg':{'close_cb':'s:job12_cb','mode':'raw'}}
    let job13 = {'job_cmd':'git --help','job_arg':{'close_cb':'s:job13_cb','mode':'raw'}}
    let job14 = {'job_cmd':'git --help','job_arg':{'close_cb':'s:job14_cb','mode':'raw'}}
    let job15 = {'job_cmd':'git --help','job_arg':{'close_cb':'s:job15_cb','mode':'raw'}}
    let job16 = {'job_cmd':'git --help','job_arg':{'close_cb':'s:job16_cb','mode':'raw'}}
    let job17 = {'job_cmd':'git --help','job_arg':{'close_cb':'s:job17_cb','mode':'raw'}}
    let job18 = {'job_cmd':'git --help','job_arg':{'close_cb':'s:job18_cb','mode':'raw'}}
    let job19 = {'job_cmd':'git --help','job_arg':{'close_cb':'s:job19_cb','mode':'raw'}}
    let job20 = {'job_cmd':'git --help','job_arg':{'close_cb':'s:job20_cb','mode':'raw'}}
    let job21 = {'job_cmd':'git --help','job_arg':{'close_cb':'s:job21_cb','mode':'raw'}}
    let job22 = {'job_cmd':'git --help','job_arg':{'close_cb':'s:job22_cb','mode':'raw'}}
    let job23 = {'job_cmd':'git --help','job_arg':{'close_cb':'s:job23_cb','mode':'raw'}}
    let job24 = {'job_cmd':'git --help','job_arg':{'close_cb':'s:job24_cb','mode':'raw'}}
    let job25 = {'job_cmd':'git --help','job_arg':{'close_cb':'s:job25_cb','mode':'raw'}}

    let job_chain = { 
                \ 'job_list':[job1,job2],
                \ 'name': 'node1',
                \ 'node_list':[
                \     {
                    \         'name': 'node2',
                    \         'job_list':[job3,job4],
                    \         'node_list':[],
                    \         'next_node':{
                    \             'name': 'node3',
                    \             'job_list':[job5,job6],
                    \             'node_list':[],
                    \             'next_node':v:null
                    \         }
                    \     },
                    \     {
                        \         'job_list':[job7,job8],
                        \         'node_list':[],
                        \         'next_node':{
                        \             'name': 'node4',
                        \             'job_list':[job9,job10],
                        \             'node_list':[],
                        \             'next_node':{
                        \                 'name': 'node5',
                        \                 'job_list':[job11,job12],
                        \                 'node_list':[],
                        \                 'next_node':v:null
                        \             }
                        \         }
                        \     },
                        \ ],
                        \ 'next_node':{
                        \    'name': 'node6',
                        \    'job_list':[job13,job14],
                        \    'node_list':[
                        \        {
                            \            'name': 'node7',
                            \            'job_list':[],
                            \            'node_list':[],
                            \            'next_node':{
                            \                'name': 'node8',
                            \                'job_list':[job15,job16],
                            \                'node_list':[],
                            \                'next_node':{
                            \                    'name': 'node9',
                            \                    'job_list':[job17],
                            \                    'node_list':[],
                            \                   'next_node':v:null
                            \                }
                            \            }
                            \        },
                            \    ],
                            \    'next_node':{
                            \       'name': 'node10',
                            \       'job_list':[job18],
                            \       'node_list':[],
                            \       'next_node':{
                            \           'name': 'node11',
                            \           'job_list':[job19],
                            \           'node_list':[],
                            \           'next_node':{
                            \               'name': 'node12',
                            \               'job_list':[job20],
                            \               'node_list':[],
                            \               'next_node':v:null
                            \           }
                            \       }
                            \    }
                            \ }
                            \ }

    call vim_job_chain#execute_chain_node(job_chain,v:null)


    let job_chain2 = { 
                \ 'job_list':[job1,job2],
                \ 'name': 'node1',
                \ 'node_list':[],
                \ 'next_node': {
                \     'name': 'node2',
                \     'job_list':[job3,job4],
                \     'node_list':[],
                \     'next_node':{
                \         'name': 'node3',
                \         'job_list':[job5,job6],
                \         'node_list':[],
                \         'next_node':v:null
                \         }
                \     },
                \ }

    let job_chain3 = {
                \ 'job_list':[job7,job8],
                \ 'name': 'node4',
                \ 'node_list':[],
                \ 'next_node': {
                \     'name': 'node5',
                \     'job_list':[job9,job10],
                \     'node_list':[],
                \     'next_node':{
                \         'name': 'node6',
                \         'job_list':[job11,job12],
                \         'node_list':[],
                \         'next_node':v:null
                \         }
                \     },
                \ }

    let job_chain4 = vim_job_chain#deepcopy_append_chain(job_chain2,job_chain3)

    call vim_job_chain#append_chain(job_chain2,job_chain3)
    if job_chain2.next_node.next_node.next_node.name != 'node4'
        echoerr 'vim_job_chain#append test failed'
    endif

    if job_chain2.next_node.next_node.next_node.next_node.name != 'node5'
        echoerr 'vim_job_chain#append test failed'
    endif

    if job_chain4 != job_chain2
        echoerr 'vim_job_chain#deepcopy_append test failed'
    endif

    let job_chain5 = vim_job_chain#build_from_jobs([job1,[job2,job3],job4])
    call vim_job_chain#chain_with_jobs(job_chain5,[[job5,job6],job7])
    " let @+ = string(job_chain5)
    " echomsg string(job_chain5)
endfunc

" call s:test()
