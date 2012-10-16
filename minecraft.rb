# rbot minecraft plugin
begin
  require 'rubygems'
rescue LoadError
end
require 'json'

class Minecraft < Plugin

  class Recipes
    def initialize(recipes)
      @recipes = recipes
      log "Loaded #{length} recipes."
    end

    def length
      @recipes.keys.length
    end

    def search(query)
      log "Search for #{query}"
      def unify(str)
        str.downcase.gsub(/(\(|\))/,'')
      end
      results = []
      @recipes.keys.each do |key|
        results << key if unify(key).include? unify(query)
        # exact match found:
        if unify(key) == unify(query)
          return [ key ]
        end
      end
      return results
    end

    def get(product)
      @recipes[product]
    end

    def craft(product, amount, checklist=[])
      return if not @recipes.has_key? product
      recipes = @recipes[product]
      if recipes.length > 1
        msg = "You can craft this in different ways:\n"
        recipes.each do |recipe|
          msg << craft_recipe(product, recipe, amount, checklist)+"\n"
        end
        return msg
      else
        return craft_recipe(product, recipes.first, amount, checklist)
      end
    end

    def craft_recipe(product, recipe, amount, checklist=[])
      checklist << product

      amount += 1 while amount % recipe['output'].to_i != 0
      factor = (amount / recipe['output'].to_i).to_i

      # ingredients how many of each..
      recipe_list = []
      recipe_crafting_list = []
      # count ingredients
      counts = {}
      recipe['recipe'].each do |ingredient|
        next if not ingredient or ingredient.empty?
        if counts.has_key? ingredient
          counts[ingredient] += 1
        else
          counts[ingredient] = 1
        end
      end
      counts.each_pair do |recipe_item, recipe_amount|
        recipe_amount *= factor

        recipe_list << "#{recipe_amount} #{recipe_item}"
        if not checklist.include? recipe_item
          recipe_crafting = craft(recipe_item, recipe_amount, checklist) 
          recipe_crafting_list << recipe_crafting if recipe_crafting
        end
      end

      msg = ''
      msg << "You craft #{amount} #{product}"
      msg << " with #{recipe_list.join ', '}."

      if not recipe_crafting_list.empty?
        msg << " (For the ingredients: #{recipe_crafting_list.join ' '})"
      end

      return msg
    end

  end

  def help(plugin, topic='')
    "Minecraft utilities: craft [amount] [item] | recipe [item] | overworld [x] [y] [z] | nether [x] [y] [z] | mcpoll [host] [port]"
  end

  def initialize
    super

    recipe_path = File.dirname(__FILE__) + '/minecraft/recipes.json'
    @recipes = Recipes.new JSON.parse(IO.read(recipe_path))
  end

  Config.register Config::StringValue.new('minecraft.numbered_stacks',
    :default => true,
    :desc => "Display amounts with stacks.")

  def craft(m, params)
    if params.has_key? :search
      results = @recipes.search params[:search].join ' '
      if results.length == 0
        m.reply "Sorry, recipe not found :("
      elsif results.length > 1
        m.reply "What did you mean? #{results.join ', '}"
      else
        product = results.first  
        if params.has_key? :amount
          amount = params[:amount].to_i
        else
          amount = 1
        end
        msg = @recipes.craft(product, amount)
        msg.split("\n").each do |line|
          m.reply line
        end
      end
    else
      m.reply "Found #{@recipes.length} crafting recipes."
    end
  end

  def recipe(m, params)
    results = @recipes.search params[:search].join ' '
    if results.length == 0
      m.reply "Sorry, recipe not found :("
    elsif results.length > 1
      m.reply "What did you mean? #{results.join ', '}"
    else
      product = results.first  
      recipe = @recipes.get(product).first

      # m.reply '[dbg] product = ' + product.inspect

      legend = {} # short character -> long ingredient name

      # build legend (manage conflicts etc.)
      recipe['recipe'].each do |ingredient|
        next if not ingredient
        # default wood plank uses oak wood planks (can use all types of wood)
        ingredient = 'Wood Planks' if ingredient == 'Oak Wood Planks'

        # short character for crafting grid and legend
        short = ingredient[0]

        # conflict search
        if legend.has_key? short and legend[short] != ingredient
          # first try to gracefully resolve the conflict by using the second word first letter
          # of both ingredients:
          if ingredient.split(' ').length > 1
            short = ingredient.split(' ')[1][0]
          elsif legend[short].split(' ').length > 1
            # change the conflicting ingredient
            new_short = legend[short].split(' ')[1][0]
            legend[new_short] = legend[short]
          end
          # TODO: test if still conflicts
        end

        legend[short] = ingredient
      end




      lines = [] # recipe lines, 3 strings each 3 characters
      line = '' # current line
      recipe['recipe'].each do |ingredient|
        # default wood plank uses oak wood planks (can use all types of wood)
        ingredient = 'Wood Planks' if ingredient == 'Oak Wood Planks'

        # search short:
        short = ' '
        legend.each_pair do |s, name|
          if name == ingredient
            short = s
            break
          end
        end

        line << short
        if line.length == 3
          lines << line
          line = ''
        end
      end

      # m.reply '[dbg] legend = ' + legend.inspect
      # m.reply '[dbg] lines = ' + lines.inspect

      # output formatting:
      m.reply lines[0] + ' | Recipe for ' + product + ((recipe['shapeless'] == 1) ? ' (shapeless)' : '')
      m.reply lines[1] + ' |'
      legend_list = []
      legend.each_pair { |short, name|
        legend_list << [short, name].join('=')
      }
      m.reply lines[2] + ' | ' + legend_list.join(' ')



=begin
      t = []
      legend.each_pair do |short, name|
        t << '%s=%s' % [short, name]
      end
      tmp << ' ' + t.join(' ')

      m.reply tmp
=end
      




    end
  end

  def overworld_nether(m, params)
    coords = coords(m, params)
    if not coords
      return
    end
    x, y, z = coords

    m.reply "Overworld(#{x}, #{y}, #{z}) -> Nether(#{(x/8).floor}, #{y}, #{(z/8).floor})"
  end

  def nether_overworld(m, params)
    coords = coords(m, params)
    if not coords
      return
    end
    x, y, z = coords

    m.reply "Nether(#{x}, #{y}, #{z}) -> Overworld(#{x*8}, #{y}, #{z*8})"
  end

  def poll(m, params)
    host = params[:host]
    port = params[:port]
    @socket = TCPSocket.open(host, port)
    # --> byte 254 (0xFE)
    @socket.write([0xFE].pack('c'))
    s = StringIO.new @socket.read
    # should return 0xFF
    if s.read(1) != "\xFF"
      m.reply 'invalid server reply'
      return
    end

    # read short (length of string)
    len = s.read(2).unpack('n').first.to_i
    welcome = s.read(len*2)
    welcome = Iconv.conv('utf-8', 'utf-16be', welcome)
    welcome, current, max = welcome.split("\xC2\xA7")
    m.reply "The server responded: #{welcome} (#{current}/#{max})"
    @socket.close
  end

  private

  def coords(m, params)
    return nil if not params.has_key? :coords or params[:coords].empty?
    begin
      # split the list of values by space or comma
      coords = params[:coords]
      if coords.length < 2
        coords = params[:coords].join.split(',')
      end
      coords.map { |n| n.strip } # remove whitespaces & convert to integers

      # either x, y, z OR x, z
      if coords.length == 3
        x, y, z = coords
      elsif coords.length == 2
        x, z = coords
        y = 0
      else
        raise 'error parsing coordinates'
      end
      coords = [x.to_i, y.to_i, z.to_i] 
    rescue
      m.reply 'error: ' + $!
      debug $!
      debug $@
      return nil
    end

    return coords
  end
end

plugin = Minecraft.new

plugin.map('craft', :action => 'craft')
plugin.map('craft [:amount] *search', :action => 'craft', :requirements => {:amount => /\d+/})

plugin.map('recipe *search', :action => 'recipe')

plugin.map('overworld *coords', :action => 'overworld_nether')
plugin.map('nether *coords', :action => 'nether_overworld')

plugin.map('mcpoll :host :port', :action => 'poll', :defaults => {:host => 'example.com', :port => 25565})


