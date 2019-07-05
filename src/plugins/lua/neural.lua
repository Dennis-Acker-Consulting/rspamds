--[[
Copyright (c) 2016, Vsevolod Stakhov <vsevolod@highsecure.ru>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]]--


if confighelp then
  return
end

local rspamd_logger = require "rspamd_logger"
local rspamd_util = require "rspamd_util"
local rspamd_kann = require "rspamd_kann"
local lua_redis = require "lua_redis"
local lua_util = require "lua_util"
local fun = require "fun"
local lua_settings = require "lua_settings"
local meta_functions = require "lua_meta"
local N = "neural"

-- Module vars
local default_options = {
  train = {
    max_trains = 1000,
    max_epoch = 1000,
    max_usages = 10,
    max_iterations = 25, -- Torch style
    mse = 0.001,
    autotrain = true,
    train_prob = 1.0,
    learn_threads = 1,
    learning_rate = 0.01,
  },
  watch_interval = 60.0,
  lock_expire = 600,
  learning_spawned = false,
  ann_expire = 60 * 60 * 24 * 2, -- 2 days
  symbol_spam = 'NEURAL_SPAM',
  symbol_ham = 'NEURAL_HAM',
}

local settings = {
  rules = {},
  prefix = 'rn', -- Neural network default prefix
  max_profiles = 3, -- Maximum number of NN profiles stored
}

local opts = rspamd_config:get_all_opt("neural")
if not opts then
  -- Legacy
  opts = rspamd_config:get_all_opt("fann_redis")
end


-- Lua script to train a row
-- Uses the following keys:
-- key1 - prefix for fann
-- key2 - fann suffix (settings id)
-- key3 - spam or ham
-- key4 - maximum trains
-- returns 1 or 0: 1 - allow learn, 0 - not allow learn
local redis_lua_script_can_train = [[
  local prefix = KEYS[1] .. KEYS[2]
  local locked = redis.call('GET', prefix .. '_locked')
  if locked then return 0 end
  local nspam = 0
  local nham = 0
  local lim = tonumber(KEYS[4])
  lim = lim + lim * 0.1

  local exists = redis.call('SISMEMBER', KEYS[1], KEYS[2])
  if not exists or tonumber(exists) == 0 then
    redis.call('SADD', KEYS[1], KEYS[2])
  end

  local ret = redis.call('LLEN', prefix .. '_spam')
  if ret then nspam = tonumber(ret) end
  ret = redis.call('LLEN', prefix .. '_ham')
  if ret then nham = tonumber(ret) end

  if KEYS[3] == 'spam' then
    if nham <= lim and nham + 1 >= nspam then
      return tostring(nspam + 1)
    else
      return tostring(-(nspam))
    end
  else
    if nspam <= lim and nspam + 1 >= nham then
      return tostring(nham + 1)
    else
      return tostring(-(nham))
    end
  end

  return tostring(0)
]]
local redis_can_train_id = nil

-- Lua script to load ANN from redis
-- Uses the following keys
-- key1 - prefix for keys
-- key2 - local version
-- returns nil or bulk string if new ANN can be loaded
local redis_lua_script_maybe_load = [[
  local ver = 0
  local ret = redis.call('GET', KEYS[1] .. '_version')
  if ret then ver = tonumber(ret) end
  if ver > tonumber(KEYS[2]) then
    return {redis.call('GET', KEYS[1] .. '_data'), ret}
  end

  return tonumber(ret) or 0
]]
local redis_maybe_load_id = nil

-- Lua script to invalidate ANNs by rank
-- Uses the following keys
-- key1 - prefix for keys
-- key2 - number of elements to leave
local redis_lua_script_maybe_invalidate = [[
  local card = redis.call('ZCARD', KEYS[1])
  if card > tonumber(KEYS[2]) then
    local to_delete = redis.call('ZRANGE', KEYS[1], 0, (-(tonumber(KEYS[2] - 1)))
    for _,k in ipairs(to_delete) do
      local tb = cjson.decode(k)
      redis.call('DEL', tb.ann_key)
    end
    redis.call('ZREMRANGEBYRANK', KEYS[1], 0, (-(tonumber(KEYS[2] - 1)))
    return to_delete
  else
    return {}
  end
]]
local redis_maybe_invalidate_id = nil

-- Lua script to invalidate ANN from redis
-- Uses the following keys
-- key1 - prefix for keys
local redis_lua_script_locked_invalidate = [[
  redis.call('SET', KEYS[1] .. '_version', '0')
  redis.call('DEL', KEYS[1] .. '_spam')
  redis.call('DEL', KEYS[1] .. '_ham')
  redis.call('DEL', KEYS[1] .. '_data')
  redis.call('DEL', KEYS[1] .. '_locked')
  redis.call('DEL', KEYS[1] .. '_hostname')
  return 1
]]
local redis_locked_invalidate_id = nil

-- Lua script to invalidate ANN from redis
-- Uses the following keys
-- key1 - prefix for keys
-- key2 - current time
-- key3 - key expire
-- key4 - hostname
local redis_lua_script_maybe_lock = [[
  local locked = redis.call('GET', KEYS[1] .. '_locked')
  if locked then
    if tonumber(KEYS[2]) < tonumber(locked) then
      return false
    end
  end
  redis.call('SET', KEYS[1] .. '_locked', tostring(tonumber(KEYS[2]) + tonumber(KEYS[3])))
  redis.call('SET', KEYS[1] .. '_hostname', KEYS[4])
  return 1
]]
local redis_maybe_lock_id = nil

-- Lua script to save and unlock ANN in redis
-- Uses the following keys
-- key1 - prefix for keys
-- key2 - compressed ANN
-- key3 - expire in seconds
local redis_lua_script_save_unlock = [[
  redis.call('INCRBY', KEYS[1] .. '_version', '1')
  redis.call('DEL', KEYS[1] .. '_spam')
  redis.call('DEL', KEYS[1] .. '_ham')
  redis.call('SET', KEYS[1] .. '_data', KEYS[2])
  redis.call('DEL', KEYS[1] .. '_locked')
  redis.call('DEL', KEYS[1] .. '_hostname')
  redis.call('EXPIRE', KEYS[1] .. '_data', KEYS[3])
  redis.call('EXPIRE', KEYS[1] .. '_version', KEYS[3])
  return 1
]]
local redis_save_unlock_id = nil

local redis_params

local function load_scripts(params)
  redis_can_train_id = lua_redis.add_redis_script(redis_lua_script_can_train,
    params)
  redis_maybe_load_id = lua_redis.add_redis_script(redis_lua_script_maybe_load,
    params)
  redis_maybe_invalidate_id = lua_redis.add_redis_script(redis_lua_script_maybe_invalidate,
    params)
  redis_locked_invalidate_id = lua_redis.add_redis_script(redis_lua_script_locked_invalidate,
    params)
  redis_maybe_lock_id = lua_redis.add_redis_script(redis_lua_script_maybe_lock,
    params)
  redis_save_unlock_id = lua_redis.add_redis_script(redis_lua_script_save_unlock,
    params)
end


local function ann_scores_filter(task)

  for _,rule in pairs(settings.rules) do
    local id = '0'
    if rule.use_settings then
     local sid = task:get_settings_id()
     if sid then
      id = tostring(sid)
     end
    end
    if rule.per_user then
      local r = task:get_principal_recipient()
      id = id .. r
    end

    if rule.anns[id] and rule.anns[id].ann then
      local ann_data = task:get_symbols_tokens()
      local mt = meta_functions.rspamd_gen_metatokens(task)
      -- Add filtered meta tokens
      fun.each(function(e) table.insert(ann_data, e) end, mt)

      local score
      local out = rule.anns[id].ann:apply1(ann_data)
      score = out[1]

      local symscore = string.format('%.3f', score)
      rspamd_logger.infox(task, '%s ann score: %s', rule.name, symscore)

      if score > 0 then
        local result = score
        task:insert_result(rule.symbol_spam, result, symscore, id)
      else
        local result = -(score)
        task:insert_result(rule.symbol_ham, result, symscore, id)
      end
    end
  end
end

local function create_ann(n, nlayers)
    -- We ignore number of layers so far when using kann
  local nhidden = math.floor((n + 1) / 2)
  local t = rspamd_kann.layer.input(n)
  t = rspamd_kann.transform.relu(t)
  t = rspamd_kann.transform.tanh(rspamd_kann.layer.dense(t, nhidden));
  t = rspamd_kann.layer.cost(t, 1, rspamd_kann.cost.mse)
  return rspamd_kann.new.kann(t)
end

local function create_train_ann(rule, n, id)
  local prefix = gen_ann_prefix(rule, id)
  if not rule.anns[id] then
    rule.anns[id] = {}
  end
  -- Fix that for flexibe layers number
  if rule.anns[id].ann then
    if not is_ann_valid(rule, prefix, rule.anns[id].ann) then
      rule.anns[id].ann_train = create_ann(n, rule.nlayers)
      rule.anns[id].ann = nil
      rspamd_logger.infox(rspamd_config, 'invalidate existing ANN, create train ANN %s', prefix)
    elseif rule.train.max_usages > 0 and
        rule.anns[id].version % rule.train.max_usages == 0 then
      -- Forget last ann
      rspamd_logger.infox(rspamd_config, 'recreate ANN %s, version %s', prefix,
          rule.anns[id].version)
      rule.anns[id].ann_train = create_ann(n, rule.nlayers)
    else
      rule.anns[id].ann_train = rule.anns[id].ann
      rspamd_logger.infox(rspamd_config, 'reuse ANN for training %s', prefix)
    end
  else
    rule.anns[id].ann_train = create_ann(n, rule.nlayers)
    rspamd_logger.infox(rspamd_config, 'create train ANN %s', prefix)
    rule.anns[id].version = 0
  end
end

local function load_or_invalidate_ann(rule, data, id, ev_base)
  local ver = data[2]
  local prefix = gen_ann_prefix(rule, id)

  if not ver or not tonumber(ver) then
    rspamd_logger.errx(rspamd_config, 'cannot get version for ANN: %s', prefix)
    return
  end

  local err,ann_data = rspamd_util.zstd_decompress(data[1])
  local ann

  if err or not ann_data then
    rspamd_logger.errx(rspamd_config, 'cannot decompress ANN %s: %s', prefix, err)
    return
  else
    ann = rspamd_kann.load(ann_data)
  end

  if is_ann_valid(rule, prefix, ann) then
    if not rule.anns[id] then rule.anns[id] = {} end
    rule.anns[id].ann = ann
    rspamd_logger.infox(rspamd_config, 'loaded ANN %s version %s from redis',
      prefix, ver)
    rule.anns[id].version = tonumber(ver)
  else
    local function redis_invalidate_cb(_err, _data)
      if _err then
        rspamd_logger.errx(rspamd_config, 'cannot invalidate ANN %s from redis: %s', prefix, _err)
      elseif type(_data) == 'string' then
        rspamd_logger.infox(rspamd_config, 'invalidated ANN %s from redis: %s', prefix, _err)
        rule.anns[id].version = 0
      end
    end
    -- Invalidate ANN
    rspamd_logger.infox(rspamd_config, 'invalidate ANN %s', prefix)
    lua_redis.exec_redis_script(redis_maybe_invalidate_id,
      {ev_base = ev_base, is_write = true},
      redis_invalidate_cb,
      {prefix})
  end
end

local function ann_train_callback(rule, task, score, required_score, id)
  local train_opts = rule['train']
  local fname,suffix = gen_ann_prefix(rule, id)

  local learn_spam, learn_ham

  if train_opts.autotrain then
    if train_opts['spam_score'] then
      learn_spam = score >= train_opts['spam_score']
    else
      learn_spam = score >= required_score
    end
    if train_opts['ham_score'] then
      learn_ham = score <= train_opts['ham_score']
    else
      learn_ham = score < 0
    end
  else
    -- Train by request header
    local hdr = task:get_request_header('ANN-Train')

    if hdr then
      if hdr:lower() == 'spam' then
        learn_spam = true
      elseif hdr:lower() == 'ham' then
        learn_ham = true
      end
    end
  end


  if learn_spam or learn_ham then
    local k
    local vec_len = 0
    if learn_spam then k = 'spam' else k = 'ham' end

    local function learn_vec_cb(err)
      if err then
        rspamd_logger.errx(task, 'cannot store train vector for %s: %s', fname, err)
      else
        rspamd_logger.infox(task, "trained ANN rule %s, save %s vector, %s bytes",
          rule['name'], k, vec_len)
      end
    end

    local function can_train_cb(err, data)
      if not err and tonumber(data) > 0 then
        local coin = math.random()
        if coin < 1.0 - train_opts.train_prob then
          rspamd_logger.infox(task, 'probabilistically skip sample: %s', coin)
          return
        end
        local ann_data = task:get_symbols_tokens()
        local mt = meta_functions.rspamd_gen_metatokens(task)
        -- Add filtered meta tokens
        fun.each(function(e) table.insert(ann_data, e) end, mt)
        -- Check NaNs in train data
        if fun.all(function(e) return e == e end, ann_data) then
          local str = rspamd_util.zstd_compress(table.concat(ann_data, ';'))
          vec_len = #str

          lua_redis.redis_make_request(task,
            rule.redis,
            nil,
            true, -- is write
            learn_vec_cb, --callback
            'LPUSH', -- command
            {fname .. '_' .. k, str} -- arguments
          )
        else
          rspamd_logger.errx(task, "do not store learn vector as it contains %s NaN values",
            fun.length(fun.filter(function(e) return e ~= e end, ann_data)))
        end

      else
        if err then
          rspamd_logger.errx(task, 'cannot check if we can train %s: %s', fname, err)
        elseif tonumber(data) < 0 then
          rspamd_logger.infox(task, "cannot learn ANN %s: too many %s samples: %s",
            fname, k, -tonumber(data))
        end
      end
    end

    lua_redis.exec_redis_script(redis_can_train_id,
      {task = task, is_write = true},
      can_train_cb,
      {gen_ann_prefix(rule, nil), suffix, k, tostring(train_opts.max_trains)})
  end
end

local function train_ann(rule, _, ev_base, elt, worker)
  local spam_elts = {}
  local ham_elts = {}
  elt = tostring(elt)
  local prefix = gen_ann_prefix(rule, elt)

  local function redis_unlock_cb(err)
    if err then
      rspamd_logger.errx(rspamd_config, 'cannot unlock ANN %s from redis: %s',
        prefix, err)
    end
  end

  local function redis_save_cb(err)
    if err then
      rspamd_logger.errx(rspamd_config, 'cannot save ANN %s to redis: %s',
        prefix, err)
      lua_redis.redis_make_request_taskless(ev_base,
        rspamd_config,
        rule.redis,
        nil,
        false, -- is write
        redis_unlock_cb, --callback
        'DEL', -- command
        {prefix .. '_locked'}
      )
    else
      rspamd_logger.infox(rspamd_config, 'saved ANN %s, key: %s_data', elt, prefix)
    end
  end

  local function ann_trained(err, data)
    rule.learning_spawned = false
    if err then
      rspamd_logger.errx(rspamd_config, 'cannot train ANN %s: %s',
          prefix, err)
      lua_redis.redis_make_request_taskless(ev_base,
          rspamd_config,
          rule.redis,
          nil,
          true, -- is write
          redis_unlock_cb, --callback
          'DEL', -- command
          {prefix .. '_locked'}
      )
    else
      rspamd_logger.infox(rspamd_config, 'trained ANN %s, %s bytes',
          prefix, #data)
      local ann_data = rspamd_util.zstd_compress(data)
      rule.anns[elt].ann_train = rspamd_kann.load(data)
      rule.anns[elt].version = rule.anns[elt].version + 1
      rule.anns[elt].ann = rule.anns[elt].ann_train
      rule.anns[elt].ann_train = nil
      lua_redis.exec_redis_script(redis_save_unlock_id,
        {ev_base = ev_base, is_write = true},
        redis_save_cb,
        {prefix, tostring(ann_data), tostring(rule.ann_expire)})
    end
  end

  local function redis_ham_cb(err, data)
    if err or type(data) ~= 'table' then
      rspamd_logger.errx(rspamd_config, 'cannot get ham tokens for ANN %s from redis: %s',
        prefix, err)
      lua_redis.redis_make_request_taskless(ev_base,
        rspamd_config,
        rule.redis,
        nil,
        true, -- is write
        redis_unlock_cb, --callback
        'DEL', -- command
        {prefix .. '_locked'}
      )
    else
      -- Decompress and convert to numbers each training vector
      ham_elts = fun.totable(fun.map(function(tok)
        local _,str = rspamd_util.zstd_decompress(tok)
        return fun.totable(fun.map(tonumber, rspamd_str_split(tostring(str), ';')))
      end, data))

      -- Now we need to join inputs and create the appropriate test vectors
      local n = rspamd_config:get_symbols_count() +
          meta_functions.rspamd_count_metatokens()

      -- Now we can train ann
      if not rule.anns[elt] or not rule.anns[elt].ann_train then
        -- Create ann if it does not exist
        create_train_ann(rule, n, elt)
      end

      if #spam_elts + #ham_elts < rule.train.max_trains / 2 then
        -- Invalidate ANN as it is definitely invalid
        local function redis_invalidate_cb(_err, _data)
          if _err then
            rspamd_logger.errx(rspamd_config, 'cannot invalidate ANN %s from redis: %s', prefix, _err)
          elseif type(_data) == 'string' then
            rspamd_logger.infox(rspamd_config, 'invalidated ANN %s from redis: %s', prefix, _err)
            rule.anns[elt].version = 0
          end
        end
        -- Invalidate ANN
        rspamd_logger.infox(rspamd_config, 'invalidate ANN %s: training data is invalid', prefix)
        lua_redis.exec_redis_script(redis_locked_invalidate_id,
          {ev_base = ev_base, is_write = true},
          redis_invalidate_cb,
          {prefix})
      else
        local inputs, outputs = {}, {}

        for _,e in ipairs(spam_elts) do
          if e == e then
            inputs[#inputs + 1] = e
            outputs[#outputs + 1] = {1.0}
          end
        end
        for _,e in ipairs(ham_elts) do
          if e == e then
            inputs[#inputs + 1] = e
            outputs[#outputs + 1] = {0.0}
          end
        end


        local function train()
          rule.anns[elt].ann_train:train1(inputs, outputs, {
            lr = rule.train.learning_rate,
            max_epoch = rule.train.max_iterations,
            cb = function(iter, train_cost, _)
              if math.floor(iter / rule.train.max_iterations * 10) % 10 == 0 then
                rspamd_logger.infox(rspamd_config, "learned %s iterations, error: %s",
                    iter, train_cost)
              end
            end
          })

          local out = rule.anns[elt].ann_train:save()
          return out
        end

        rule.learning_spawned = true

        worker:spawn_process{
          func = train,
          on_complete = ann_trained,
        }
      end
    end
  end

  local function redis_spam_cb(err, data)
    if err or type(data) ~= 'table' then
      rspamd_logger.errx(rspamd_config, 'cannot get spam tokens for ANN %s from redis: %s',
        prefix, err)
      lua_redis.redis_make_request_taskless(ev_base,
        rspamd_config,
        rule.redis,
        nil,
        true, -- is write
        redis_unlock_cb, --callback
        'DEL', -- command
        {prefix .. '_locked'}
      )
    else
      -- Decompress and convert to numbers each training vector
      spam_elts = fun.totable(fun.map(function(tok)
        local _,str = rspamd_util.zstd_decompress(tok)
        return fun.totable(fun.map(tonumber, rspamd_str_split(tostring(str), ';')))
      end, data))
      lua_redis.redis_make_request_taskless(ev_base,
        rspamd_config,
        rule.redis,
        nil,
        false, -- is write
        redis_ham_cb, --callback
        'LRANGE', -- command
        {prefix .. '_ham', '0', '-1'}
      )
    end
  end

  local function redis_lock_cb(err, data)
    if err then
      rspamd_logger.errx(rspamd_config, 'cannot lock ANN %s from redis: %s',
        prefix, err)
    elseif type(data) == 'number' then
      -- Can train ANN
      lua_redis.redis_make_request_taskless(ev_base,
        rspamd_config,
        rule.redis,
        nil,
        false, -- is write
        redis_spam_cb, --callback
        'LRANGE', -- command
        {prefix .. '_spam', '0', '-1'}
      )

      rspamd_config:add_periodic(ev_base, 30.0,
        function(_, _)
          local function redis_lock_extend_cb(_err, _)
            if _err then
              rspamd_logger.errx(rspamd_config, 'cannot lock ANN %s from redis: %s',
                prefix, _err)
            else
              rspamd_logger.infox(rspamd_config, 'extend lock for ANN %s for 30 seconds',
                prefix)
            end
          end
          if rule.learning_spawned then
            lua_redis.redis_make_request_taskless(ev_base,
              rspamd_config,
              rule.redis,
              nil,
              true, -- is write
              redis_lock_extend_cb, --callback
              'INCRBY', -- command
              {prefix .. '_locked', '30'}
            )
          else
            return false -- do not plan any more updates
          end

          return true
        end
      )
      rspamd_logger.infox(rspamd_config, 'lock ANN %s for learning', prefix)
    else
      rspamd_logger.infox(rspamd_config, 'do not learn ANN %s, locked by another process', prefix)
    end
  end
  if rule.learning_spawned then
    rspamd_logger.infox(rspamd_config, 'do not learn ANN %s, already learning another ANN', prefix)
    return
  end
  lua_redis.exec_redis_script(redis_maybe_lock_id,
    {ev_base = ev_base, is_write = true},
    redis_lock_cb,
    {prefix, tostring(os.time()), tostring(rule.lock_expire), rspamd_util.get_hostname()})
end

local function maybe_train_anns(rule, cfg, ev_base, worker)
  local function members_cb(err, data)
    if err then
      rspamd_logger.errx(rspamd_config, 'cannot get FANNS list from redis: %s', err)
    elseif type(data) == 'table' then
      fun.each(function(elt)
        elt = tostring(elt)
        local prefix = gen_ann_prefix(rule, elt)
        rspamd_logger.infox(cfg, "check ANN %s", prefix)
        local redis_len_cb = function(_err, _data)
          if _err then
            rspamd_logger.errx(rspamd_config,
              'cannot get FANN trains %s from redis: %s', prefix, _err)
          elseif _data and type(_data) == 'number' or type(_data) == 'string' then
            if tonumber(_data) and tonumber(_data) >= rule.train.max_trains then
              rspamd_logger.infox(rspamd_config,
                'need to learn ANN %s after %s learn vectors (%s required)',
                prefix, tonumber(_data), rule.train.max_trains)
              train_ann(rule, cfg, ev_base, elt, worker)
            else
              rspamd_logger.infox(rspamd_config,
                'no need to learn ANN %s %s learn vectors (%s required)',
                prefix, tonumber(_data), rule.train.max_trains)
            end
          end
        end

        lua_redis.redis_make_request_taskless(ev_base,
          rspamd_config,
          rule.redis,
          nil,
          false, -- is write
          redis_len_cb, --callback
          'LLEN', -- command
          {prefix .. '_spam'}
        )
      end,
      data)
    end
  end

  -- First we need to get all anns stored in our Redis
  lua_redis.redis_make_request_taskless(ev_base,
    rspamd_config,
    rule.redis,
    nil,
    false, -- is write
    members_cb, --callback
    'SMEMBERS', -- command
    {gen_ann_prefix(rule, nil)} -- arguments
  )

  return rule.watch_interval
end

-- This function loads new ann from Redis
-- This is based on `profile` attribute.
-- ANN is loaded from `profile.ann_key`
-- Rank of `profile` key is also increased, unfortunately, it means that we need to
-- serialize profile one more time and set its rank to the current time
-- set.ann fields are set according to Redis data received
local function load_new_ann(rule, ev_base, set, profile, min_diff)

end

-- Used to check an element in Redis serialized as JSON
-- for some specific rule + some specific setting
-- This function tries to load more fresh or more specific ANNs in lieu of
-- the existing ones.
local function process_existing_ann(rule, ev_base, set, profiles)
  local my_symbols = set.symbols
  local min_diff = math.huge
  local sel_elt

  for _,elt in fun.iter(profiles) do
    if elt and elt.symbols then
      local dist = lua_util.distance_sorted(elt.symbols, my_symbols)

      if dist < #my_symbols * .3 then
        if dist < min_diff then
          min_diff = dist
          sel_elt = elt
        end
      end
    end
  end

  if sel_elt then
    -- We can load element from ANN
    if set.ann then
      -- We have an existing ANN, probably the same...
      if set.ann.digest == sel_elt.digest then
        -- Same ANN, check version
        if set.ann.version < sel_elt.version then
          -- Load new ann
          rspamd_logger.infox(rspamd_config, 'ann %s is changed,' ..
              'our version = %s, remote version = %s',
              rule.prefix .. ':' .. set.name,
              set.ann.version,
              sel_elt.version)
          load_new_ann(rule, ev_base, set, sel_elt, min_diff)
        else
          lua_util.debugm(N, rspamd_config, 'ann %s is not changed,' ..
              'our version = %s, remote version = %s',
              rule.prefix .. ':' .. set.name,
              set.ann.version,
              sel_elt.version)
        end
      else
        -- We have some different ANN, so we need to compare distance
        if set.ann.distance > min_diff then
          -- Load more specific ANN
          rspamd_logger.infox(rspamd_config, 'more specific ann is available for %s,' ..
              'our distance = %s, remote distance = %s',
              rule.prefix .. ':' .. set.name,
              set.ann.distance,
              min_diff)
          load_new_ann(rule, ev_base, set, sel_elt, min_diff)
        else
          lua_util.debugm(N, rspamd_config, 'ann %s is not changed or less specific,' ..
              'our distance = %s, remote distance = %s',
              rule.prefix .. ':' .. set.name,
              set.ann.distance,
              min_diff)
        end
      end
    else
      -- We have no ANN, load new one
      load_new_ann(rule, ev_base, set, sel_elt, min_diff)
    end
  end
end

-- Used to deserialise ANN element from a list
local function load_ann_profile(element)
  local ucl = require "ucl"

  local parser = ucl.parser()
  local res,ucl_err = parser:parse_string(element)
  if not res then
    rspamd_logger.warnx(rspamd_config, 'cannot parse ANN from redis: %s',
        ucl_err)
    return nil
  else
    return parser:get_object()
  end
end

-- Function to check or load ANNs from Redis
local function check_anns(rule, cfg, ev_base)
  for _,set in pairs(rule.settings) do
    local function members_cb(err, data)
      if err then
        rspamd_logger.errx(cfg, 'cannot get ANNs list from redis: %s',
            err)
      elseif type(data) == 'table' then
        process_existing_ann(rule, ev_base, set, fun.map(load_ann_profile, data))
      end
    end

    -- Extract all profiles for some specific settings id
    -- Get the last `max_profiles` recently used
    -- Select the most appropriate to our profile but it should not differ by more
    -- than 30% of symbols
    lua_redis.redis_make_request_taskless(ev_base,
        cfg,
        rule.redis,
        nil,
        false, -- is write
        members_cb, --callback
        'ZREVRANGE', -- command
        {set.prefix, '0', tostring(settings.max_profiles)} -- arguments
    )
  end -- Cycle over all settings

  return rule.watch_interval
end

-- Function to clean up old ANNs
local function cleanup_anns(rule, cfg, ev_base)
  for _,set in pairs(rule.settings) do
    local function invalidate_cb(err, data)
      if err then
        rspamd_logger.errx(cfg, 'cannot exec invalidate script in redis: %s',
            err)
      elseif type(data) == 'table' then
        for _,expired in ipairs(data) do
          local profile = load_ann_profile(expired)
          rspamd_logger.infox(cfg, 'invalidated ANN for %s; redis key: %s; version=%s',
              rule.prefix .. ':' .. set.name,
              profile.ann_key,
              profile.version)
        end
      end
    end
    lua_redis.exec_redis_script(redis_maybe_invalidate_id,
        {ev_base = ev_base, is_write = true},
        invalidate_cb,
        {set.prefix, tostring(settings.max_profiles)})
  end
end

local function ann_push_vector(task)
  if task:has_flag('skip') then return end
  if not settings.allow_local and lua_util.is_rspamc_or_controller(task) then return end
  local scores = task:get_metric_score()
  for _,rule in pairs(settings.rules) do
    local sid = "0"
    if rule.use_settings then
      sid = tostring(task:get_settings_id())
    end
    if rule.per_user then
      local r = task:get_principal_recipient()
      sid = sid .. r
    end
    ann_train_callback(rule, task, scores[1], scores[2], sid)
  end
end


-- Generate redis prefix for specific rule and specific settings
local function redis_ann_prefix(rule, settings_name)
  -- We also need to count metatokens:
  local n = meta_functions.version
  return string.format('%s_%s_%d_%s',
      settings.prefix, rule.prefix, n, settings_name)
end

-- This function is used to adjust profiles and allowed setting ids for each rule
-- It must be called when all settings are already registered (e.g. at post-init for config)
local function process_rules_settings()
  local function process_settings_elt(rule, selt)
    local profile = rule.profile[selt.name]
    if profile then
      -- Use static user defined profile
      -- Ensure that we have an array...
      lua_util.debugm(N, rspamd_config, "use static profile for %s (%s)",
          rule.prefix, selt.name)
      if not profile[1] then profile = lua_util.keys(profile) end
      selt.symbols = profile
    else
      lua_util.debugm(N, rspamd_config, "use dynamic cfg based profile for %s (%s)",
          rule.prefix, selt.name)
    end

    -- Generic stuff
    table.sort(selt.symbols)
    selt.digest = lua_util.table_digest(selt.symbols)
    selt.prefix = redis_ann_prefix(rule, selt.name)

    lua_redis.register_prefix(selt.prefix, N,
        string.format('NN prefix for rule "%s"; settings id "%s"',
            rule.prefix, selt.name))
  end

  for _,rule in pairs(opts.rules) do
    if not rule.allowed_settings then
      -- Extract all settings ids
      rule.allowed_settings = lua_util.keys(lua_settings.all_settings)
    end

    -- Convert to a map <setting_id> -> true
    rule.allowed_settings = lua_util.list_to_hash(rule.allowed_settings)

    -- Check if we can work without settings
    if type(rule.default) ~= 'boolean' then
      rule.default = true
    end

    rule.settings = {}

    if rule.default then
      local default_settings = {
        symbols = lua_util.keys(lua_settings.default_symbols),
        name = 'default'
      }

      process_settings_elt(rule, default_settings)
      rule.settings[-1] = default_settings -- Magic constant, but OK as settings are positive int32
    end

    -- Now, for each allowed settings, we store sorted symbols + digest
    -- We set table rule.settings[id] -> { name = name, symbols = symbols, digest = digest }
    for s,_ in pairs(rule.allowed_settings) do
      -- Here, we have a name, set of symbols and
      local selt = lua_settings.settings_by_id(s)
      rule.settings[s] = {
        symbols = selt.symbols, -- Already sorted
        name = selt.name
      }

      process_settings_elt(rule, rule.settings[s])
    end
  end
end

redis_params = lua_redis.parse_redis_server('neural')

if not redis_params then
  redis_params = lua_redis.parse_redis_server('fann_redis')
end

-- Initialization part
if not (opts and type(opts) == 'table') or not redis_params then
  rspamd_logger.infox(rspamd_config, 'Module is unconfigured')
  lua_util.disable_module(N, "redis")
  return
end

local rules = opts['rules']

if not rules then
  -- Use legacy configuration
  rules = {}
  rules['default'] = opts
end

local id = rspamd_config:register_symbol({
  name = 'NEURAL_CHECK',
  type = 'postfilter,nostat',
  priority = 6,
  callback = ann_scores_filter
})

for k,r in pairs(rules) do
  local def_rules = lua_util.override_defaults(default_options, r)
  def_rules['redis'] = redis_params
  def_rules['anns'] = {} -- Store ANNs here

  if not def_rules.prefix then
    def_rules.prefix = k
  end
  if not def_rules.name then
    def_rules.name = k
  end
  if def_rules.train.max_train then
    def_rules.train.max_trains = def_rules.train.max_train
  end

  rspamd_logger.infox(rspamd_config, "register ann rule %s", k)
  settings.rules[k] = def_rules
  rspamd_config:set_metric_symbol({
    name = def_rules.symbol_spam,
    score = 0.0,
    description = 'Neural network SPAM',
    group = 'neural'
  })
  rspamd_config:register_symbol({
    name = def_rules.symbol_spam,
    type = 'virtual,nostat',
    parent = id
  })

  rspamd_config:set_metric_symbol({
    name = def_rules.symbol_ham,
    score = -0.0,
    description = 'Neural network HAM',
    group = 'neural'
  })
  rspamd_config:register_symbol({
    name = def_rules.symbol_ham,
    type = 'virtual,nostat',
    parent = id
  })
end

rspamd_config:register_symbol({
  name = 'NEURAL_LEARN',
  type = 'idempotent,nostat',
  priority = 5,
  callback = ann_push_vector
})

-- Add training scripts
for k,rule in pairs(settings.rules) do
  load_scripts(rule.redis)
  -- We also need to deal with settings
  rspamd_config:add_post_init(process_rules_settings)
  -- This function will check ANNs in Redis when a worker is loaded
  rspamd_config:add_on_load(function(cfg, ev_base, worker)
    rspamd_config:add_periodic(ev_base, 0.0,
        function(_, _)
          return check_anns(rule, cfg, ev_base)
        end)

    if worker:is_primary_controller() then
      -- We also want to train neural nets when they have enough data
      rspamd_config:add_periodic(ev_base, 0.0,
          function(_, _)
            cleanup_anns(rule, cfg, ev_base)
            return maybe_train_anns(rule, cfg, ev_base, worker)
          end)
    end
  end)
end
