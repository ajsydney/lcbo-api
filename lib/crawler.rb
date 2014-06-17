require 'boticus'

class Crawler < Boticus::Bot
  class UnknownJobTypeError < StandardError; end

  class ProductListsGetter
    include LCBO::CrawlKit::Crawler

    def request(params)
      LCBO.product_list(params[:next_page] || 1)
    end

    def continue?(current_params)
      current_params[:next_page] ? true : false
    end

    def reduce
      responses.map { |params| params[:product_ids] }.flatten
    end
  end

  def init(crawl = nil)
    @model = (crawl || Crawl.init)
  end

  def log(level, msg, payload = {})
    super
    model.log(msg, level, payload)
  end

  def prepare
    log :info, 'Enumerating product job queue ...'
    model.push_jobs(:product, ProductListsGetter.run)

    log :info, 'Enumerating store job queue ...'
    model.push_jobs(:store, LCBO.store_list[:store_ids])
  end

  desc 'Crawling stores, products, and inventories'
  task :crawl do
    while (pair = model.popjob)
      kind, id = *pair

      case kind
      when 'product'
        place_product_and_inventories(id)
      when 'store'
        place_store(id)
      end

      model.total_finished_jobs += 1
      model.save
    end

    puts
  end

  desc 'Refreshing fuzzy search dictionaries'
  task :recache_fuzz do
    Fuzz.recache
  end

  desc 'Performing calculations'
  task :calculate do
    ActiveRecord::Base.connection.execute <<-SQL
      UPDATE stores SET
        products_count = (
          SELECT COUNT(inventories.product_id)
            FROM inventories
           WHERE inventories.store_id = stores.id
        ),

        inventory_count = (
          SELECT SUM(inventories.quantity)
            FROM inventories
           WHERE inventories.store_id = stores.id
        ),

        inventory_price_in_cents = (
          SELECT SUM(inventories.quantity * products.price_in_cents)
            FROM products
              LEFT JOIN inventories ON products.id = inventories.product_id
           WHERE inventories.store_id = stores.id
        ),

        inventory_volume_in_milliliters = (
          SELECT SUM(inventories.quantity * products.volume_in_milliliters)
            FROM products
              LEFT JOIN inventories ON products.id = inventories.product_id
           WHERE inventories.store_id = stores.id
        )
    SQL
  end

  desc 'Performing diff'
  task :diff do
    model.diff!
  end

  desc 'Marking dead products'
  task :mark_dead_products do
    Product.where(id: model.removed_product_ids).update_all(is_dead: true)
  end

  desc 'Marking dead stores'
  task :mark_dead_stores do
    Store.where(id: model.removed_store_ids).update_all(is_dead: true)
  end

  desc 'Marking dead inventories'
  task :mark_dead_inventories do
    Inventory.where(product_id: model.removed_product_ids).update_all(is_dead: true)
    Inventory.where(store_id: model.removed_store_ids).update_all(is_dead: true)
  end

  desc 'Marking orphaned inventories'
  task :update_orphaned_inventories do
    Inventory.where('crawl_id != ?', model.id).update_all(quantity: 0, is_dead: true)
  end

  desc 'Exporting CSV data'
  task :export do
    Exporter.run(model.id)
  end

  desc 'Flushing page caches'
  task :flush_caches do
    LCBOAPI.flush
  end

  def place_store(id)
    log :dot, "Placing store: #{id}"

    attrs = LCBO.store(id)
    attrs[:is_dead]     = false
    attrs[:crawl_id]    = model.id
    attrs[:postal_code] = attrs[:postal_code].gsub(' ', '')

    Store.place(attrs)

    model.total_stores += 1
    model.save
    model.crawled_store_ids << id
  rescue LCBO::CrawlKit::NotFoundError
    log :warn, "Skipping store ##{id}, it does not exist."
  end

  # TODO: Make this not so beastly!
  def place_product_and_inventories(id)
    log :dot, "Placing product ##{id} and inventories"

    pa = LCBO.product(id)
    ia = LCBO.inventory(id)

    ia[:inventory_count].tap do |count|
      pa.tap do |p|
        p[:crawl_id] = model.id
        p[:is_dead] = false
        p[:inventory_count] = count
        p[:inventory_price_in_cents] = (p[:price_in_cents] * count)
        p[:inventory_volume_in_milliliters] = (p[:volume_in_milliliters] * count)
      end
    end

    Product.place(pa)

    ia[:inventories].each do |inv|
      inv[:crawl_id] = model.id
      inv[:is_dead] = false
      inv[:product_id] = id
      Inventory.place(inv)
    end

    model.total_products                                += 1
    model.total_inventories                             += ia[:inventories].size
    model.total_product_inventory_count                 += ia[:inventory_count]
    model.total_product_inventory_price_in_cents        += pa[:inventory_price_in_cents]
    model.total_product_inventory_volume_in_milliliters += pa[:inventory_volume_in_milliliters]

    model.save

    model.crawled_product_ids << id
  rescue LCBO::CrawlKit::NotFoundError, LCBO::CrawlKit::RedirectedError
    log :warn, "Skipping product ##{id}, it does not exist"
  end
end
