--[[
talks.lua — talks.yml から発表リストを生成する Pandoc/Quarto Lua フィルタ

使い方（.qmd 内）:

  ::: {.talks-list types="invited"}
  :::

  ::: {.talks-list types="oral,poster" selected="true" group="year" order="asc" mark-poster="true"}
  :::

Div の属性:
  types        : カンマ区切りの type（invited, oral, poster）。省略時は全件
  selected     : "true" なら selected: true の項目だけ（invited は常に含める）
  group        : "year" なら年ごとの見出しを付ける
  level        : 年見出しのレベル（既定 3）
  order        : 年の中の並び。"asc" または "desc"（既定 "desc"）。年見出し自体は常に新しい順
  mark-poster  : "true" ならポスターに *(Poster)* を付ける
  show-year    : "true" なら日付に年を含める（group="year" でない場合の既定は true）

データファイル: メタデータ `talks-data`（既定 "talks.yml"）
--]]

local stringify = pandoc.utils.stringify

local MONTHS = { "Jan.", "Feb.", "Mar.", "Apr.", "May", "June",
                 "July", "Aug.", "Sept.", "Oct.", "Nov.", "Dec." }

local data_path = "talks.yml"
local talks_cache = nil

local function file_exists(p)
  local f = io.open(p, "r")
  if f then f:close() return true end
  return false
end

local function resolve_path(p)
  local candidates = { p }
  if quarto and quarto.project and quarto.project.directory then
    table.insert(candidates, quarto.project.directory .. "/" .. p)
  end
  if PANDOC_STATE and PANDOC_STATE.input_files and PANDOC_STATE.input_files[1] then
    local dir = pandoc.path.directory(PANDOC_STATE.input_files[1])
    table.insert(candidates, pandoc.path.join({ dir, p }))
  end
  for _, c in ipairs(candidates) do
    if file_exists(c) then return c end
  end
  return nil
end

local function load_talks()
  if talks_cache then return talks_cache end
  local path = resolve_path(data_path)
  if not path then
    error("talks.lua: data file not found: " .. data_path)
  end
  local fh = io.open(path, "r")
  local content = fh:read("a")
  fh:close()
  -- YAML を Markdown のメタデータとして読む（文字列は Markdown として解釈される）
  local doc = pandoc.read("---\n" .. content .. "\n---\n", "markdown")
  local list = doc.meta.talks
  if not list then
    error("talks.lua: top-level key `talks:` not found in " .. path)
  end
  local talks = {}
  for i, t in ipairs(list) do
    local item = {
      idx      = i,
      title    = t.title,
      event    = t.event,
      place    = t.place,
      date     = stringify(t.date or ""),
      datetext = t["date-text"],
      type     = stringify(t.type or ""),
      selected = (t.selected == true) or (stringify(t.selected or "") == "true"),
      award    = t.award,
    }
    if not item.date:match("^%d%d%d%d%-%d%d%-%d%d$") then
      error("talks.lua: entry " .. i .. " has invalid date '" .. item.date .. "' (use YYYY-MM-DD)")
    end
    if item.type ~= "invited" and item.type ~= "oral" and item.type ~= "poster" then
      error("talks.lua: entry " .. i .. " has invalid type '" .. item.type .. "'")
    end
    table.insert(talks, item)
  end
  talks_cache = talks
  return talks
end

-- MetaValue -> Inlines
local function to_inlines(v)
  if v == nil then return pandoc.Inlines({}) end
  local tv = pandoc.utils.type(v)
  if tv == "Inlines" then return v end
  if tv == "Blocks" then
    -- 1段落だけならその中身を使う
    if #v == 1 and (v[1].t == "Para" or v[1].t == "Plain") then
      return v[1].content
    end
    return pandoc.utils.blocks_to_inlines(v)
  end
  return pandoc.Inlines({ pandoc.Str(stringify(v)) })
end

local function format_date(item, show_year)
  if item.datetext then
    local s = stringify(item.datetext)
    if show_year then s = s .. ", " .. item.date:sub(1, 4) end
    return s
  end
  local y, m, d = item.date:match("^(%d+)%-(%d+)%-(%d+)$")
  local s = MONTHS[tonumber(m)] .. " " .. tostring(tonumber(d))
  if show_year then s = s .. ", " .. y end
  return s
end

local function render_item(item, opts)
  local inl = pandoc.Inlines({})
  local title = pandoc.Inlines({ pandoc.Str("“") })
  title:extend(to_inlines(item.title))
  title:insert(pandoc.Str("”"))
  inl:insert(pandoc.Strong(title))
  inl:insert(pandoc.Space())
  inl:insert(pandoc.Str("—"))
  inl:insert(pandoc.Space())
  inl:extend(to_inlines(item.event))
  if item.place then
    inl:insert(pandoc.Str(","))
    inl:insert(pandoc.Space())
    inl:extend(to_inlines(item.place))
  end
  inl:insert(pandoc.Str(","))
  inl:insert(pandoc.Space())
  inl:insert(pandoc.Str(format_date(item, opts.show_year) .. "."))

  local notes = {}
  if opts.mark_poster and item.type == "poster" then
    table.insert(notes, pandoc.Inlines({ pandoc.Str("Poster") }))
  end
  if item.award then
    table.insert(notes, to_inlines(item.award))
  end
  if #notes > 0 then
    local n = pandoc.Inlines({ pandoc.Str("(") })
    for k, x in ipairs(notes) do
      if k > 1 then n:insert(pandoc.Str(";")); n:insert(pandoc.Space()) end
      n:extend(x)
    end
    n:insert(pandoc.Str(")"))
    inl:insert(pandoc.Space())
    inl:insert(pandoc.Emph(n))
  end
  return { pandoc.Plain(inl) }
end

local function split_csv(s)
  local out = {}
  for x in s:gmatch("[^,%s]+") do out[x] = true end
  return out
end

local function build(div)
  local a = div.attributes
  local types = a.types and split_csv(a.types) or nil
  local only_selected = a.selected == "true"
  local group_year = a.group == "year"
  local level = tonumber(a.level or "3")
  local asc = a.order == "asc"
  local show_year
  if a["show-year"] then show_year = a["show-year"] == "true" else show_year = not group_year end
  local opts = { mark_poster = a["mark-poster"] == "true", show_year = show_year }

  local items = {}
  for _, t in ipairs(load_talks()) do
    local ok = (types == nil) or types[t.type]
    if ok and only_selected and t.type ~= "invited" and not t.selected then ok = false end
    if ok then table.insert(items, t) end
  end

  local function cmp(x, y)
    if x.date == y.date then return x.idx < y.idx end
    if asc then return x.date < y.date else return x.date > y.date end
  end

  local blocks = pandoc.Blocks({})
  if #items == 0 then return blocks end

  if group_year then
    local years, byyear = {}, {}
    for _, t in ipairs(items) do
      local y = t.date:sub(1, 4)
      if not byyear[y] then byyear[y] = {}; table.insert(years, y) end
      table.insert(byyear[y], t)
    end
    table.sort(years, function(x, y) return x > y end)
    for _, y in ipairs(years) do
      table.sort(byyear[y], cmp)
      blocks:insert(pandoc.Header(level, y))
      local li = {}
      for _, t in ipairs(byyear[y]) do table.insert(li, render_item(t, opts)) end
      blocks:insert(pandoc.BulletList(li))
    end
  else
    table.sort(items, cmp)
    local li = {}
    for _, t in ipairs(items) do table.insert(li, render_item(t, opts)) end
    blocks:insert(pandoc.BulletList(li))
  end
  return blocks
end

return {
  {
    Meta = function(meta)
      if meta["talks-data"] then data_path = stringify(meta["talks-data"]) end
    end,
  },
  {
    Div = function(div)
      if div.classes:includes("talks-list") then
        return build(div)
      end
    end,
  },
}
