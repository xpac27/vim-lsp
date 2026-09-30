let s:keyword_kind = 14
let s:snippet_kind = 15
let s:max_locality_lines = 2000

" Rank LSP items without modifying the response or filtering candidates out.
" context.base is the default query. With context.line and context.position,
" textEdit items use their own replacement start instead. All character offsets
" follow vim-lsp's position helpers (character indexes, not byte indexes).
function! lsp#internal#completion#ranking#rank(items, context) abort
    let l:items = copy(a:items)
    let l:max = get(a:context, 'max', len(l:items))
    if len(l:items) < 2 || len(l:items) > l:max
        return l:items
    endif

    let l:records = []
    let l:groups = {}
    let l:has_sort_text = 0
    for l:index in range(len(l:items))
        let l:item = l:items[l:index]
        let l:filter_text = get(l:item, 'filterText', '')
        if empty(l:filter_text)
            let l:filter_text = get(l:item, 'label', '')
        endif
        let l:base = s:item_base(l:item, a:context)
        let l:record = {
            \ 'item': l:item,
            \ 'index': l:index,
            \ 'text': l:filter_text,
            \ 'filter_text_length': empty(l:base) ? 0 : strchars(l:filter_text),
            \ 'sort_text': get(l:item, 'sortText', ''),
            \ 'locality_score': 0,
            \ }
        let l:has_sort_text = l:has_sort_text || !empty(l:record['sort_text'])
        call add(l:records, l:record)
        if !has_key(l:groups, l:base)
            let l:groups[l:base] = []
        endif
        call add(l:groups[l:base], l:record)
    endfor

    " Comparing sortText only when BOTH items have it is not transitive: three
    " items can form a comparison cycle. If the server supplies any sort keys,
    " use the LSP label fallback for every missing key. With no keys at all,
    " leave room for locality and keep server order when the query is empty.
    if l:has_sort_text
        for l:record in l:records
            if empty(l:record['sort_text'])
                let l:record['sort_text'] = get(l:record['item'], 'label', '')
            endif
        endfor
    endif

    " Usually there is just one query. Grouping keeps native fuzzy matching
    " batched even when a server returns several different textEdit ranges.
    for [l:base, l:group] in items(l:groups)
        call lsp#internal#completion#matching#score(l:group, l:base, get(a:context, 'fuzzy', v:true))
    endfor
    if get(a:context, 'locality', v:false)
        call s:add_locality_scores(l:records, a:context)
    endif

    call sort(l:records, function('s:compare_records'))
    return map(l:records, {_, record -> record['item']})
endfunction

function! s:item_base(item, context) abort
    let l:base = get(a:context, 'base', '')
    if !has_key(a:context, 'line') || !has_key(a:context, 'position')
        return l:base
    endif
    let l:range = lsp#utils#text_edit#get_range(get(a:item, 'textEdit', {}))
    if empty(l:range)
        return l:base
    endif
    let l:start = l:range['start']
    let l:position = a:context['position']
    if l:start['line'] != l:position['line'] || l:start['character'] < 0 || l:start['character'] > l:position['character']
        return l:base
    endif
    return strcharpart(a:context['line'], l:start['character'], l:position['character'] - l:start['character'])
endfunction

function! s:add_locality_scores(records, context) abort
    let l:bufnr = get(a:context, 'bufnr', -1)
    " [:keyword:] uses the current buffer's iskeyword. Do not switch buffers
    " (and potentially trigger autocmds) while preparing a completion menu.
    if l:bufnr != bufnr('%') || !bufloaded(l:bufnr)
        return
    endif

    " Locality cannot change an order already decided by matching or sortText.
    " In particular, clangd often supplies a distinct sort key for every item;
    " avoid scanning the buffer at all when there are no ties to resolve.
    let l:groups = {}
    for l:record in a:records
        let l:key = string([l:record['matched'], l:record['score'], l:record['sort_text']])
        if !has_key(l:groups, l:key)
            let l:groups[l:key] = []
        endif
        call add(l:groups[l:key], l:record)
    endfor
    let l:candidates = {}
    for l:group in values(l:groups)
        if len(l:group) < 2
            continue
        endif
        for l:record in l:group
            let l:kind = get(l:record['item'], 'kind', 0)
            if l:kind != s:keyword_kind && l:kind != s:snippet_kind && !empty(l:record['text'])
                let l:candidates[l:record['text']] = 1
            endif
        endfor
    endfor
    if empty(l:candidates)
        return
    endif

    let l:position = get(a:context, 'position', {})
    let l:cursor_lnum = get(l:position, 'line', 0) + 1
    let l:start_character = get(a:context, 'start_character', get(l:position, 'character', 0))
    let l:end_character = get(l:position, 'character', l:start_character)
    " getbufinfo().linecount is unavailable on some supported Vim versions.
    let l:line_count = line('$')

    let l:first_lnum = max([1, l:cursor_lnum - (s:max_locality_lines / 2)])
    let l:last_lnum = min([l:line_count, l:first_lnum + s:max_locality_lines - 1])
    let l:first_lnum = max([1, l:last_lnum - s:max_locality_lines + 1])
    " Scan once for the whole candidate set, not once per completion item.
    let l:locality = s:collect_locality(l:first_lnum, l:last_lnum,
        \ l:cursor_lnum, l:start_character, l:end_character, l:candidates)

    for l:record in a:records
        let l:kind = get(l:record['item'], 'kind', 0)
        if l:kind != s:keyword_kind && l:kind != s:snippet_kind
            let l:record['locality_score'] = get(l:locality, l:record['text'], 0)
        endif
    endfor
endfunction

function! s:collect_locality(first_lnum, last_lnum, cursor_lnum, start_character, end_character, candidates) abort
    let l:locality = {}
    let l:lnum = a:first_lnum
    for l:line in getline(a:first_lnum, a:last_lnum)
        if l:lnum == a:cursor_lnum && a:start_character < a:end_character
            let l:line = strcharpart(l:line, 0, a:start_character)
                \ . repeat(' ', a:end_character - a:start_character)
                \ . strcharpart(l:line, a:end_character)
        endif
        for l:word in split(l:line, '[^[:keyword:]]\+')
            if has_key(a:candidates, l:word)
                let l:distance = abs(l:lnum - a:cursor_lnum)
                let l:score = s:max_locality_lines + 1 - l:distance
                let l:locality[l:word] = max([get(l:locality, l:word, 0), l:score])
            endif
        endfor
        let l:lnum += 1
    endfor
    return l:locality
endfunction

function! s:compare_records(left, right) abort
    if a:left['matched'] != a:right['matched']
        return a:left['matched'] ? -1 : 1
    endif
    if a:left['score'] != a:right['score']
        return a:left['score'] > a:right['score'] ? -1 : 1
    endif

    if a:left['sort_text'] !=# a:right['sort_text']
        return a:left['sort_text'] <# a:right['sort_text'] ? -1 : 1
    endif

    if a:left['locality_score'] != a:right['locality_score']
        return a:left['locality_score'] > a:right['locality_score'] ? -1 : 1
    endif

    if a:left['filter_text_length'] != a:right['filter_text_length']
        return a:left['filter_text_length'] < a:right['filter_text_length'] ? -1 : 1
    endif

    return a:left['index'] == a:right['index'] ? 0 : a:left['index'] < a:right['index'] ? -1 : 1
endfunction
