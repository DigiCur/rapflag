require 'csv'
require 'open-uri'
require 'faraday'
require 'fileutils'
require 'rapflag/history'
require 'poloniex'
require 'json'
require 'pp'

module RAPFLAG

  class Poloniex < History
    attr_reader :complete_balances, :active_loans, :lending_history, :deposits, :withdrawals, :deposit_addresses,
        :trade_history, :available_account_balances, :open_orders, :tradable_balances,
        :output_prefix

    def dump_history
      load_history_info
      FileUtils.makedirs(RAPFLAG.outputDir) unless File.directory?(RAPFLAG.outputDir)
      CSV.open("#{@output_prefix}/trade_history.csv",'w+',
               :col_sep => COLUMN_SEPARATOR,
               :write_headers=> true,
               :headers => [ 'currency_pair'] + @trade_history.values.first.first.to_h.keys
        ) do |csv|
        @trade_history.each do |currency_pair, trades|
          trades.each do |trace|
            csv << [ currency_pair] + trace.to_h.values
          end
        end
      end
      CSV.open("#{@output_prefix}/lending_history.csv",'w+',
               :col_sep => COLUMN_SEPARATOR,
               :write_headers=> true,
               :headers => @lending_history.first.to_h.keys
        ) do |csv|
        @lending_history.each do |info|
          csv << info.to_h.values
        end
      end
      CSV.open("#{@output_prefix}/tradable_balances.csv",'w+',
               :col_sep => COLUMN_SEPARATOR,
               :write_headers=> true,
               :headers => [ 'from_currency', 'to_from_currency', ]
        ) do |csv|
        @tradable_balances.each do |currency_pair, balance|
          balance.each do |info|
            csv << [ currency_pair] + info
          end
        end
      end
      CSV.open("#{@output_prefix}/complete_balances.csv",'w+',
               :col_sep => COLUMN_SEPARATOR,
               :write_headers=> true,
               :headers => [ 'currency', 'available', 'onOrders', 'btcValue' ]
        ) do |csv|
        @complete_balances.each do |balance|
          csv << [balance[0]] + balance[1].values
        end
      end
      CSV.open("#{@output_prefix}/active_loans.csv",'w+',
               :col_sep => COLUMN_SEPARATOR,
               :write_headers=> true,
               :headers => [ 'key', 'id', 'currency', 'rate', 'amount', 'duration', 'autoRenew', 'date', 'fees', ]
        ) do |csv|
        @active_loans.each do |key, loans|
          loans.each do | loan |
            csv << [key] + loan.values
          end
        end
      end

      CSV.open("#{@output_prefix}/available_account_balances.csv",'w+',
               :col_sep => COLUMN_SEPARATOR,
               :write_headers=> true,
               :headers => [ 'key', 'currency', 'balance']
        ) do |csv|
        @available_account_balances.each do |key, balances|
          balances.each do |currency, balance|
            csv << [key, currency, balance]
          end
        end
      end
      CSV.open("#{@output_prefix}/deposit_addresses.csv",'w+',
               :col_sep => COLUMN_SEPARATOR,
               :write_headers=> true,
               :headers => [ 'currency', 'id']
        ) do |csv|
        @deposit_addresses.each do |currency, id|
          csv << [currency, id]
        end
      end
      CSV.open("#{@output_prefix}/withdrawals.csv",'w+',
               :col_sep => COLUMN_SEPARATOR,
               :write_headers=> true,
               :headers => @deposits.first.to_h.keys
        ) do |csv|
        @deposits.each do |info|
          csv << info.to_h.values
        end
      end
      CSV.open("#{@output_prefix}/deposits.csv",'w+',
               :col_sep => COLUMN_SEPARATOR,
               :write_headers=> true,
               :headers => @withdrawals.first.to_h.keys
        ) do |csv|
        @withdrawals.each do |info|
          csv << info.to_h.values
        end
      end
    end

    def find_per_currency_and_day(items, currency, date)
      puts "Searching for #{currency} in day #{date}" if $VERBOSE
      start_time  = date.to_time.to_i
      end_time    = (date + 1).to_time.to_i
      found = items.find_all{|item| item.currency.eql?(currency) && item.timestamp >= start_time && item.timestamp < end_time}
      puts "find_per_currency_and_day: found #{found.size} #{found.first} #{found.last}" if $VERBOSE
      found
    end

    def find_lending_info_day(currency, date)
      puts "Searching lending (close) for #{currency} in day #{date}" if $VERBOSE
      found = @lending_history.find_all { |item| item.currency.eql?(currency) && date.eql?(Date.parse(item.close)) }
      puts "find_lending_info_day: found #{found.size} #{found.first} #{found.last}" if $VERBOSE
      found
    end

    # type is either buy or sell
    def find_day_trade(currency, date, type)
      found = []
      @trade_history.each do |currency_pair, trades|
        next unless /^#{currency}/.match(currency_pair)
        trades.each do |trade|
          if trade.type.eql?(type) && date.eql?(Date.parse(trade.date))
            trade.currency_pair = currency_pair
            found << trade
          end
        end
      end
      puts "find_day_trade: #{date} #{currency} found #{found.size}" if $VERBOSE
      found
    end
    def create_csv_file
      puts "create_csv_file: already done"
    end

    def fetch_csv_history
      load_history_info
      @trade_history.values.collect{|values| values.collect{|x| x.date} }.max

      max_time = [ @deposits.collect{|x| x.timestamp}.max,
                   Time.parse(@trade_history.values.collect{|values| values.collect{|x| x.date} }.max.max).to_i,
                   Time.parse(@lending_history.collect{|x| x.close}.max).to_i,
                   @withdrawals.collect{|x| x.timestamp}.max,].max
      min_time = [ @deposits.collect{|x| x.timestamp}.min,
                   Time.parse(@trade_history.values.collect{|values| values.collect{|x| x.date} }.min.min).to_i,
                   Time.parse(@lending_history.collect{|x| x.close}.min).to_i,
                   @withdrawals.collect{|x| x.timestamp}.min,].min

      min_date = Time.at(min_time).to_date - 1
      max_date = Time.at(max_time).to_date

      puts "We start using the available_account_balances"
      pp @available_account_balances
      pp @complete_balances
      @available_account_balances.each do |key, balances|
        balances.each do |currency, balance|
          puts "Calculation history for #{key} #{currency} with current balance of #{balance}"
          out_name = "#{@output_prefix}/#{key}_#{currency}.csv"
          FileUtils.makedirs(File.dirname(out_name)) unless File.exists?(File.dirname(out_name))
          @history = []
          current_day = min_date
          current_balance  = 0.0
          while (current_day < max_date)
            puts "#{key}: at #{current_day}" if current_day.day == 1 && current_day.month % 3 == 1
            entry = OpenStruct.new
            entry.current_day = current_day
            entry.balance_BEG = current_balance

            deposits = find_per_currency_and_day(@deposits, currency,current_day)
            sum_deposits = 0.0; deposits.each{ |x| sum_deposits += x.amount.to_f }

            withdrawals = find_per_currency_and_day(@withdrawals, currency, current_day)
            sum_withdrawals = 0.0; withdrawals.each{ |x| sum_withdrawals += x.amount.to_f }

            lendings = find_lending_info_day(currency, current_day)
            # fee field is negative, therefore we let sum_fee be negative, too
            income = 0.0;  sum_fee = 0.0; lendings.each{ |x| income += x.earned.to_f; sum_fee += x.fee.to_f }

            # End_of_Day_Balance = End_of_Day_Balance(-1) + Deposits - Withdrawals + Lending_Income - Trading_Fees + Purchases - Sales
            sales = find_day_trade(currency, current_day, 'buy')
            sum_sales = 0.0; sales.each{ |sale| sum_sales += sale.amount.to_f*sale.rate.to_f }

            purchases = find_day_trade(currency, current_day, 'sell')
            sum_purchase = 0.0; purchases.each{ |purchase| sum_purchase += purchase.amount.to_f*purchase.rate.to_f }
            diff_day = sum_deposits - sum_withdrawals + sum_purchase - sum_sales + income

            entry.deposits = sum_deposits
            entry.income = income
            entry.withdraw = sum_withdrawals
            entry.sales = sum_sales
            entry.purchases = sum_purchase
            entry.balance_END = current_balance + diff_day
            entry.fees = sum_fee
            entry.day_difference = diff_day
            @history << entry
            current_day += 1
            # balance for previous day
            current_balance = entry.balance_END
          end
          next unless @history.size > 0
          CSV.open(out_name,'w+',
                  :col_sep => COLUMN_SEPARATOR,
                  :write_headers=> true,
                  :headers => @history.first.to_h.keys
            ) do |csv|
            @history.each do |info|
              csv << info.to_h.values
            end
          end
        end
      end
    end
    private
    def check_config
      @output_prefix = File.join(RAPFLAG.outputDir, 'poloniex')
      @spec_data = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'spec', 'data'))
      ['poloniex_api_key',
       'poloniex_secret',
       ].each do |item|
        raise "Must define #{item} in config.yml" unless Config[item]
      end
      ::Poloniex.setup do | config |
          config.key    = Config['poloniex_api_key']
          config.secret = Config['poloniex_secret']
      end
      nil
    end
    private

    def load_lending_history
      # we must load this history in pieces, as we cannot return all items at once
      end_time = Time.now.to_i
      limit = 1000
      full_history = []
      while true
        @lending_history = []
        puts "After #{full_history.size} items. Loading upto #{limit} lending_history items before #{Time.at(end_time)}"
        lendings = load_or_save_json(:lending_history, {:start => 0, :end_time => end_time, :limit => limit})
        break if lendings.size == 0
        lendings.each_with_index {|item| full_history.push(OpenStruct.new(item.clone)) };
        min_time = lendings.collect{|x| x['close']}.min
        min_time_i = Time.parse(min_time).to_i
        end_time = min_time_i-1
        break if defined?(RSpec) # We don't simulate loading more than 1 json file
      end
      @lending_history = full_history
      puts "Loaded #{@lending_history.size} lending_history items"
    end

    def load_or_save_json(name, param = nil)
      load_json = nil
      json_file = File.join(@spec_data, name.to_s + '.json')
      parse_body = "@#{name} = JSON.parse(body)"
      body = nil
      if File.directory?(@spec_data) && File.exist?(json_file) && defined?(RSpec)
        body = IO.read(json_file)
      else
        if param
          if param.is_a?(String)
            load_json = "::Poloniex.#{name.to_s}('#{param}').body"
          else
            load_json = "::Poloniex.#{name.to_s}(#{param.values.join(',')}).body"
          end
        else
          load_json = "::Poloniex.#{name.to_s}.body"
        end
        # puts "Poloniex version #{::Poloniex::VERSION}: Will call '#{load_json}' for #{name}"
        body = eval(load_json)
        FileUtils.makedirs(File.dirname(json_file))
        File.open(json_file, 'w+') { |f| f.write(body)} if body && defined?(RSpec)
      end
      eval(parse_body) if body
    rescue => error
      puts "Calling version #{::Poloniex::VERSION} '#{load_json}' for #{name} failed with error: #{error}"
      # puts "Backtrace #{error.backtrace.join("\n")}"
      exit(1)
    end
    def load_history_info
      return if @balances && @balances.size > 0
      check_config
      begin
        @balances = load_or_save_json(:balances)
      rescue => error
        puts "Error was #{error.inspect}"
        puts "Calling @balances from poloniex failed. Configuration was"
        pp ::Poloniex.configuration
        puts "Backtrace #{error.backtrace.join("\n")}"
        exit 1
      end
      load_lending_history
      @active_loans = load_or_save_json(:active_loans)
      @available_account_balances = load_or_save_json(:available_account_balances)
      all = load_or_save_json(:complete_balances)
      @complete_balances = all.find_all{ | currency, values| values["available"].to_f != 0.0 }
      @deposit_addresses = load_or_save_json(:deposit_addresses)

      @deposits_withdrawals  = load_or_save_json(:deposits_withdrawls)
      # deposits and withdrawals have a different structure
      @deposits = []
      @deposits_withdrawals['deposits'].each {|x| @deposits << OpenStruct.new(x) };
      @withdrawals =[]
      @deposits_withdrawals['withdrawals'].each {|x| @withdrawals << OpenStruct.new(x) };
      @open_orders  = load_or_save_json(:open_orders, 'all')
      info  = load_or_save_json(:trade_history, 'all')
      @trade_history = {}
      info.each do |currency_pair, trades|
        @trade_history[currency_pair] = []
        trades.each {|x| @trade_history[currency_pair] << OpenStruct.new(x) };
        @trade_history[currency_pair].sort!{|x,y| x[:date] <=> y[:date]}.collect{ |x| x[:date]}
      end
      # @trade_history.values.first.first.tradeID
      @tradable_balances  = load_or_save_json(:tradable_balances)
      @active_loans   # key
      @provided_loans = []; @active_loans['provided'].each {|x| @provided_loans << OpenStruct.new(x) };
      @used_loans = []; @active_loans['used'].each {|x| @used_loans << OpenStruct.new(x) };

    end
  end
end
