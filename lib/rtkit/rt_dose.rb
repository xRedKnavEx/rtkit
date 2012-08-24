module RTKIT

  # The RTDose class contains methods that are specific for this modality (RTDOSE).
  #
  # === Inheritance
  #
  # * RTDose inherits all methods and attributes from the Series class.
  #
  class RTDose < Series

    # The Plan which this RTDose series belongs to.
    attr_reader :plan
    # An array of dose Volume instances associated with this RTDose series.
    attr_accessor :volumes

    # Creates a new RTDose instance by loading the relevant information from the specified DICOM object.
    # The Series Instance UID string value is used to uniquely identify a RTDose instance.
    #
    # === Parameters
    #
    # * <tt>dcm</tt> -- An instance of a DICOM object (DICOM::DObject) with modality 'RTDOSE'.
    # * <tt>study</tt> -- The Study instance that this RTDose belongs to.
    #
    def self.load(dcm, study)
      raise ArgumentError, "Invalid argument 'dcm'. Expected DObject, got #{dcm.class}." unless dcm.is_a?(DICOM::DObject)
      raise ArgumentError, "Invalid argument 'study'. Expected Study, got #{study.class}." unless study.is_a?(Study)
      raise ArgumentError, "Invalid argument 'dcm'. Expected DObject with modality 'RTDOSE', got #{dcm.value(MODALITY)}." unless dcm.value(MODALITY) == 'RTDOSE'
      # Required attributes:
      series_uid = dcm.value(SERIES_UID)
      # Optional attributes:
      class_uid = dcm.value(SOP_CLASS)
      date = dcm.value(SERIES_DATE)
      time = dcm.value(SERIES_TIME)
      description = dcm.value(SERIES_DESCR)
      series_uid = dcm.value(SERIES_UID)
      # Get the corresponding Plan:
      plan = self.plan(dcm, study)
      # Create the RTDose instance:
      dose = self.new(series_uid, plan, :class_uid => class_uid, :date => date, :time => time, :description => description)
      dose.add(dcm)
      return dose
    end

    # Identifies the Plan that the RTDose object belongs to.
    # If the referenced instances (Plan, StructureSet, ImageSeries & Frame) does not exist, they are created by this method.
    #
    def self.plan(dcm, study)
      raise ArgumentError, "Invalid argument 'dcm'. Expected DObject, got #{dcm.class}." unless dcm.is_a?(DICOM::DObject)
      raise ArgumentError, "Invalid argument 'study'. Expected Study, got #{study.class}." unless study.is_a?(Study)
      raise ArgumentError, "Invalid argument 'dcm'. Expected DObject with modality 'RTDOSE', got #{dcm.value(MODALITY)}." unless dcm.value(MODALITY) == 'RTDOSE'
      # Extract the Frame of Reference UID:
      begin
        frame_of_ref = dcm.value(FRAME_OF_REF)
      rescue
        frame_of_ref = nil
      end
      # Extract referenced Plan SOP Instance UID:
      begin
        ref_plan_uid = dcm[REF_PLAN_SQ][0].value(REF_SOP_UID)
      rescue
        ref_plan_uid = nil
      end
      # Create the Frame if it doesn't exist:
      f = study.patient.dataset.frame(frame_of_ref)
      f = Frame.new(frame_of_ref, study.patient) unless f
      # Create the Plan, StructureSet & ImageSeries if the referenced Plan doesn't exist:
      plan = study.fseries(ref_plan_uid)
      unless plan
        # Create ImageSeries (assuming modality CT):
        is = ImageSeries.new(RTKIT.series_uid, 'CT', f, study)
        study.add_series(is)
        # Create StructureSet:
        struct = StructureSet.new(RTKIT.sop_uid, is)
        study.add_series(struct)
        # Create Plan:
        plan = Plan.new(ref_plan_uid, struct)
        study.add_series(plan)
      end
      return plan
    end

    # Creates a new RTDose instance.
    #
    # === Parameters
    #
    # * <tt>series_uid</tt> -- The Series Instance UID string.
    # * <tt>plan</tt> -- The Plan instance that this RTDose series belongs to.
    # * <tt>options</tt> -- A hash of parameters.
    #
    # === Options
    #
    # * <tt>:date</tt> -- String. The Series Date (DICOM tag '0008,0021').
    # * <tt>:time</tt> -- String. The Series Time (DICOM tag '0008,0031').
    # * <tt>:description</tt> -- String. The Series Description (DICOM tag '0008,103E').
    #
    def initialize(series_uid, plan, options={})
      raise ArgumentError, "Invalid argument 'series_uid'. Expected String, got #{series_uid.class}." unless series_uid.is_a?(String)
      raise ArgumentError, "Invalid argument 'plan'. Expected Plan, got #{plan.class}." unless plan.is_a?(Plan)
      # Pass attributes to Series initialization:
      options[:class_uid] = '1.2.840.10008.5.1.4.1.1.481.2' # RT Dose Storage
      super(series_uid, 'RTDOSE', plan.study, options)
      @plan = plan
      # Default attributes:
      @volumes = Array.new
      @associated_volumes = Hash.new
      # Register ourselves with the Plan:
      @plan.add_rt_dose(self)
    end

    # Returns true if the argument is an instance with attributes equal to self.
    #
    def ==(other)
      if other.respond_to?(:to_rt_dose)
        other.send(:state) == state
      end
    end

    alias_method :eql?, :==

    # Registers a DICOM Object to the RTDose series, and processes it
    # to create (and reference) a DoseVolume instance linked to this RTDose series.
    #
    def add(dcm)
      raise ArgumentError, "Invalid argument 'dcm'. Expected DObject, got #{dcm.class}." unless dcm.is_a?(DICOM::DObject)
      DoseVolume.load(dcm, self)
    end

    # Adds a DoseVolume instance to this RTDose series.
    #
    def add_volume(volume)
      raise ArgumentError, "Invalid argument 'volume'. Expected DoseVolume, got #{volume.class}." unless volume.is_a?(DoseVolume)
      @volumes << volume unless @associated_volumes[volume.uid]
      @associated_volumes[volume.uid] = volume
    end

    # Generates a Fixnum hash value for this instance.
    #
    def hash
      state.hash
    end

    # Returns a DoseVolume which is the sum of the volumes of this instance.
    # With the individual DoseVolumes corresponding to the dose for a particular
    # beam, the sum DoseVolume corresponds to the summed dose of the entire
    # treatment plan.
    #
    def sum
      if @sum
        # If the sum volume has already been created, return it instead of recreating:
        return @sum
      else
        if @volumes.length > 0
          nr_frames = @volumes.first.images.length
          # Create the sum DoseVolume instance:
          sop_uid = @volumes.first.sop_uid + ".1"
          @sum = DoseVolume.new(sop_uid, @volumes.first.frame, @volumes.first.dose_series, :sum => true)
          # Sum the dose of the various DoseVolumes:
          dose_sum = NArray.int(nr_frames, @volumes.first.images.first.columns, @volumes.first.images.first.rows)
          @volumes.each { |volume| dose_sum += volume.dose_arr }
          # Convert dose float array to integer pixel values of a suitable range,
          # along with a corresponding scaling factor:
          sum_scaling_coeff = dose_sum.max / 65000.0
          if sum_scaling_coeff == 0.0
            pixel_values = NArray.int(nr_frames, @volumes.first.images.first.columns, @volumes.first.images.first.rows)
          else
            pixel_values = dose_sum * (1 / sum_scaling_coeff)
          end
          # Set the scaling coeffecient:
          @sum.scaling = sum_scaling_coeff
          # Collect the rest of the image information needed to create new dose images:
          sop_uids = RTKIT.sop_uids(nr_frames)
          slice_positions = @volumes.first.images.collect {|img| img.pos_slice}
          columns = @volumes.first.images.first.columns
          rows = @volumes.first.images.first.rows
          pos_x = @volumes.first.images.first.pos_x
          pos_y = @volumes.first.images.first.pos_y
          col_spacing = @volumes.first.images.first.col_spacing
          row_spacing = @volumes.first.images.first.row_spacing
          cosines = @volumes.first.images.first.cosines
          # Create dose images for our sum dose volume:
          nr_frames.times do |i|
            img = Image.new(sop_uids[i], @sum)
            # Fill in image information:
            img.columns = columns
            img.rows = rows
            img.pos_x = pos_x
            img.pos_y = pos_y
            img.pos_slice = slice_positions[i]
            img.col_spacing = col_spacing
            img.row_spacing = row_spacing
            img.cosines = cosines
            # Fill in the pixel frame data:
            img.narray = pixel_values[i, true, true]
          end
          return @sum
        end
      end
    end

    # Returns self.
    #
    def to_rt_dose
      self
    end

    # Returns the Volume instance mathcing the specified SOP Instance UID (if an argument is used).
    # If a specified UID doesn't match, nil is returned.
    # If no argument is passed, the first Volume instance associated with the RTDose is returned.
    #
    # === Parameters
    #
    # * <tt>uid</tt> -- String. The value of the SOP Instance UID element.
    #
    def volume(*args)
      raise ArgumentError, "Expected one or none arguments, got #{args.length}." unless [0, 1].include?(args.length)
      if args.length == 1
        raise ArgumentError, "Expected String (or nil), got #{args.first.class}." unless [String, NilClass].include?(args.first.class)
        return @associated_volumes[args.first]
      else
        # No argument used, therefore we return the first Volume instance:
        return @volumes.first
      end
    end


    private


    # Returns the attributes of this instance in an array (for comparison purposes).
    #
    def state
       [@series_uid, @volumes]
    end

  end

end