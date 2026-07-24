let s:keyword_kind = 14
let s:snippet_kind = 15
let s:max_locality_lines = 2000

function! lsp#internal#completion#ranking#rank(items, context) abort
    let l:items = copy(a:items)
    let l:max = get(a:context, 'max', len(l:items))
    if len(l:items) < 2 || len(l:items) > l:max
        return l:items
    endif

    let l:records = []
    for l:index in range(len(l:items))
        let l:item = l:items[l:index]
        let l:filter_text = get(l:item, 'filterText', '')
        if empty(l:filter_text)
            let l:filter_text = get(l:item, 'label', '')
        endif
        call add(l:records, {
            \ 'item': l:item,
            \ 'index': l:index,
            \ 'filter_text': l:filter_text,
            \ 'filter_text_length': strchars(l:filter_text),
            \ 'sort_text': get(l:item, 'sortText', ''),
            \ 'fuzzy_score': -1,
            \ 'locality_score': 0,
            \ })
    endfor

    call s:add_fuzzy_scores(l:records, get(a:context, 'base', ''), get(a:context, 'fuzzy', v:true))
    if get(a:context, 'locality', v:false)
        call s:add_locality_scores(l:records, a:context)
    endif

    call sort(l:records, function('s:compare_records'))
    return map(l:records, {_, record -> record['item']})
endfunction

function! s:add_fuzzy_scores(records, base, fuzzy) abort
    if empty(a:base)
        for l:record in a:records
            let l:record['fuzzy_score'] = 0
        endfor
        return
    endif

    if a:fuzzy && exists('*matchfuzzypos')
        let l:result = matchfuzzypos(a:records, a:base, {'key': 'filter_text'})
        let l:scores = {}
        if !empty(l:result[0])
            for l:index in range(len(l:result[0]))
                let l:scores[l:result[0][l:index]['index']] = l:result[2][l:index]
            endfor
        endif
        for l:record in a:records
            let l:record['fuzzy_score'] = get(l:scores, l:record['index'], -1)
        endfor
        return
    endif

    for l:record in a:records
        let l:text = l:record['filter_text']
        if l:text ==# a:base
            let l:record['fuzzy_score'] = 3
        elseif stridx(l:text, a:base) == 0
            let l:record['fuzzy_score'] = 2
        elseif get(g:, 'lsp_ignorecase', &ignorecase) && stridx(tolower(l:text), tolower(a:base)) == 0
            let l:record['fuzzy_score'] = 1
        else
            let l:record['fuzzy_score'] = 0
        endif
    endfor
endfunction

function! s:add_locality_scores(records, context) abort
    let l:bufnr = get(a:context, 'bufnr', -1)
    if l:bufnr <= 0 || !bufloaded(l:bufnr)
        return
    endif

    let l:candidates = {}
    for l:record in a:records
        let l:kind = get(l:record['item'], 'kind', 0)
        if l:kind != s:keyword_kind && l:kind != s:snippet_kind && !empty(l:record['filter_text'])
            let l:candidates[l:record['filter_text']] = 1
        endif
    endfor
    if empty(l:candidates)
        return
    endif

    let l:position = get(a:context, 'position', {})
    let l:cursor_lnum = get(l:position, 'line', 0) + 1
    let l:start_character = get(a:context, 'start_character', get(l:position, 'character', 0))
    let l:end_character = get(l:position, 'character', l:start_character)
    let l:line_count = get(getbufinfo(l:bufnr), 0, {'linecount': 0})['linecount']
    if l:line_count <= 0
        return
    endif

    let l:first_lnum = max([1, l:cursor_lnum - (s:max_locality_lines / 2)])
    let l:last_lnum = min([l:line_count, l:first_lnum + s:max_locality_lines - 1])
    let l:first_lnum = max([1, l:last_lnum - s:max_locality_lines + 1])
    let l:args = [l:first_lnum, l:last_lnum, l:cursor_lnum, l:start_character, l:end_character, l:candidates]

    if l:bufnr == bufnr('%')
        let l:locality = call(function('s:collect_locality'), l:args)
    elseif exists('*bufcall')
        let l:locality = bufcall(l:bufnr, {-> call(function('s:collect_locality'), l:args)})
    else
        return
    endif

    for l:record in a:records
        let l:kind = get(l:record['item'], 'kind', 0)
        if l:kind != s:keyword_kind && l:kind != s:snippet_kind
            let l:record['locality_score'] = get(l:locality, l:record['filter_text'], 0)
        endif
    endfor
endfunction

function! s:collect_locality(first_lnum, last_lnum, cursor_lnum, start_character, end_character, candidates) abort
    let l:locality = {}
    let l:lnum = a:first_lnum
    for l:line in getline(a:first_lnum, a:last_lnum)
        let l:byte_index = 0
        while l:byte_index < strlen(l:line)
            let l:match = matchstrpos(l:line, '\k\+', l:byte_index)
            if l:match[1] < 0
                break
            endif

            let l:word = l:match[0]
            if has_key(a:candidates, l:word)
                let l:start = strchars(strpart(l:line, 0, l:match[1]))
                let l:end = l:start + strchars(l:word)
                let l:is_current_word = l:lnum == a:cursor_lnum
                    \ && l:start < a:end_character
                    \ && l:end > a:start_character
                if !l:is_current_word
                    let l:distance = abs(l:lnum - a:cursor_lnum)
                    let l:score = s:max_locality_lines + 1 - l:distance
                    let l:locality[l:word] = max([get(l:locality, l:word, 0), l:score])
                endif
            endif
            let l:byte_index = l:match[2]
        endwhile
        let l:lnum += 1
    endfor
    return l:locality
endfunction

function! s:compare_records(left, right) abort
    if a:left['fuzzy_score'] != a:right['fuzzy_score']
        return a:left['fuzzy_score'] > a:right['fuzzy_score'] ? -1 : 1
    endif

    if !empty(a:left['sort_text']) && !empty(a:right['sort_text'])
        if a:left['sort_text'] !=# a:right['sort_text']
            return a:left['sort_text'] <# a:right['sort_text'] ? -1 : 1
        endif
    endif

    if a:left['locality_score'] != a:right['locality_score']
        return a:left['locality_score'] > a:right['locality_score'] ? -1 : 1
    endif

    if a:left['filter_text_length'] != a:right['filter_text_length']
        return a:left['filter_text_length'] < a:right['filter_text_length'] ? -1 : 1
    endif

    return a:left['index'] == a:right['index'] ? 0 : a:left['index'] < a:right['index'] ? -1 : 1
endfunction
