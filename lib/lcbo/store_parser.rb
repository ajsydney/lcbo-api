module LCBO
  class StoreParser < Parser
    FEATURE_FIELDS = {
      has_wheelchair_accessability: :wheelChair,
      has_bilingual_services:       :bilingual,
      has_product_consultant:       :wineConsultant,
      has_tasting_bar:              :tastingBar,
      has_beer_cold_room:           :beerColdRoom,
      has_special_occasion_permits: :specialPermit,
      has_vintages_corner:          :vintageCorner,
      has_transit_access:           :transitAccess }

    field :id do
      lookup(:locationNumber).to_i
    end

    field :name do
      util.titlecase(lookup(:locationIntersection))
    end

    field :tags do
      util.tagify(
        name,
        address_line_1,
        address_line_2,
        city,
        postal_code
      )
    end

    field :kind do
      lookup(:locationTypeDescription).downcase.gsub(/\s+/, '_')
    end

    field :address_line_1 do
      util.titlecase(lookup(:locationAddress1))
    end

    field :address_line_2 do
      val = lookup(:locationAddress2)
      val ? util.titlecase(val) : nil
    end

    field :city do
      util.titlecase(lookup(:locationCityName))
    end

    field :postal_code do
      if (pc = lookup(:postalCode))
        pc.sub(' ', '').upcase
      else
        nil
      end
    end

    field :telephone do
      if (tel = lookup(:phoneNumber1))
        area = lookup(:phoneAreaCode)
        "(#{area}) #{tel}"
      else
        nil
      end
    end

    field :fax do
      if (fax = lookup(:faxNumber))
        area = lookup(:phoneAreaCode)
        "(#{area}) #{fax}"
      else
        nil
      end
    end

    field :latitude do
      val = lookup(:latitude)
      val ? val.to_f : nil
    end

    field :longitude do
      val = lookup(:longitude)
      val ? val.to_f : nil
    end

    field :landmark_name do
      if (val = lookup(:anchorStoreName))
        util.titlecase(val).
          sub('Mkt', 'Market')
      else
        nil
      end
    end

    Date::DAYNAMES.map { |d| d.downcase }.each do |day|
      field :"#{day}_open" do
        val = lookup(:"#{day}OpenHour")
        val ? util.time_to_msm(val) : nil
      end

      field :"#{day}_close" do
        val = lookup(:"#{day}CloseHour")
        val ? util.time_to_msm(val) : nil
      end
    end

    FEATURE_FIELDS.each_pair do |field_name, key|
      field(field_name) { lookup(:"#{key}Code") == 'Y' }
    end

    field :has_parking do
      lookup(:parkSpaceQuantity).to_i > 0
    end
  end
end
