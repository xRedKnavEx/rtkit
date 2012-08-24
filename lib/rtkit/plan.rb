module RTKIT

  # The Plan class contains methods that are specific for this modality (RTPLAN).
  #
  # === Inheritance
  #
  # * Plan inherits all methods and attributes from the Series class.
  #
  class Plan < Series

    # An array of radiotherapy beams belonging to this Plan.
    attr_reader :beams
    # The DObject instance of this Plan.
    attr_reader :dcm
    # The patient position.
    attr_reader :patient_position
    #  An array of RTDose instances associated with this Plan.
    attr_reader :rt_doses
    #  An array of RTImage (series) instances associated with this Plan.
    attr_reader :rt_images
    # The referenced patient Setup instance.
    attr_reader :setup
    # The SOP Instance UID.
    attr_reader :sop_uid
    # The StructureSet that this Plan belongs to.
    attr_reader :struct

    # Creates a new Plan instance by loading the relevant information from the specified DICOM object.
    # The SOP Instance UID string value is used to uniquely identify a Plan instance.
    #
    # === Parameters
    #
    # * <tt>dcm</tt> -- An instance of a DICOM object (DICOM::DObject) with modality 'RTPLAN'.
    # * <tt>study</tt> -- The Study instance that this RTPlan belongs to.
    #
    def self.load(dcm, study)
      raise ArgumentError, "Invalid argument 'dcm'. Expected DObject, got #{dcm.class}." unless dcm.is_a?(DICOM::DObject)
      raise ArgumentError, "Invalid argument 'study'. Expected Study, got #{study.class}." unless study.is_a?(Study)
      raise ArgumentError, "Invalid argument 'dcm'. Expected DObject with modality 'RTPLAN', got #{dcm.value(MODALITY)}." unless dcm.value(MODALITY) == 'RTPLAN'
      # Required attributes:
      sop_uid = dcm.value(SOP_UID)
      # Optional attributes:
      class_uid = dcm.value(SOP_CLASS)
      date = dcm.value(SERIES_DATE)
      time = dcm.value(SERIES_TIME)
      description = dcm.value(SERIES_DESCR)
      series_uid = dcm.value(SERIES_UID)
      # Get the corresponding StructureSet:
      struct = self.structure_set(dcm, study)
      # Create the Plan instance:
      plan = self.new(sop_uid, struct, :class_uid => class_uid, :date => date, :time => time, :description => description, :series_uid => series_uid)
      plan.add(dcm)
      return plan
    end

    # Identifies the StructureSet that the Plan object belongs to.
    # If the referenced instances (StructureSet, ImageSeries & Frame) does not exist, they are created by this method.
    #
    def self.structure_set(dcm, study)
      raise ArgumentError, "Invalid argument 'dcm'. Expected DObject, got #{dcm.class}." unless dcm.is_a?(DICOM::DObject)
      raise ArgumentError, "Invalid argument 'study'. Expected Study, got #{study.class}." unless study.is_a?(Study)
      raise ArgumentError, "Invalid argument 'dcm'. Expected DObject with modality 'RTPLAN', got #{dcm.value(MODALITY)}." unless dcm.value(MODALITY) == 'RTPLAN'
      # Extract the Frame of Reference UID:
      begin
        frame_of_ref = dcm.value(FRAME_OF_REF)
      rescue
        frame_of_ref = nil
      end
      # Extract referenced Structure Set SOP Instance UID:
      begin
        ref_struct_uid = dcm[REF_STRUCT_SQ][0].value(REF_SOP_UID)
      rescue
        ref_struct_uid = nil
      end
      # Create the Frame if it doesn't exist:
      f = study.patient.dataset.frame(frame_of_ref)
      f = Frame.new(frame_of_ref, study.patient) unless f
      # Create the StructureSet & ImageSeries if the StructureSet doesn't exist:
      struct = study.fseries(ref_struct_uid)
      unless struct
        # Create ImageSeries (assuming modality CT):
        is = ImageSeries.new(RTKIT.series_uid, 'CT', f, study)
        study.add_series(is)
        # Create StructureSet:
        struct = StructureSet.new(ref_struct_uid, is)
        study.add_series(struct)
      end
      return struct
    end

    # Creates a new Plan instance.
    #
    # === Parameters
    #
    # * <tt>sop_uid</tt> -- The SOP Instance UID string.
    # * <tt>struct</tt> -- The StructureSet that this Plan belongs to.
    # * <tt>options</tt> -- A hash of parameters.
    #
    # === Options
    #
    # * <tt>:date</tt> -- String. The Series Date (DICOM tag '0008,0021').
    # * <tt>:time</tt> -- String. The Series Time (DICOM tag '0008,0031').
    # * <tt>:description</tt> -- String. The Series Description (DICOM tag '0008,103E').
    # * <tt>:series_uid</tt> -- String. The Series Instance UID (DICOM tag '0020,000E').
    #
    def initialize(sop_uid, struct, options={})
      raise ArgumentError, "Invalid argument 'sop_uid'. Expected String, got #{sop_uid.class}." unless sop_uid.is_a?(String)
      raise ArgumentError, "Invalid argument 'struct'. Expected StructureSet, got #{struct.class}." unless struct.is_a?(StructureSet)
      # Pass attributes to Series initialization:
      options[:class_uid] = '1.2.840.10008.5.1.4.1.1.481.5' # RT Plan Storage
      # Get a randomized Series UID unless it has been defined in the options hash:
      series_uid = options[:series_uid] || RTKIT.series_uid
      super(series_uid, 'RTPLAN', struct.study, options)
      @sop_uid = sop_uid
      @struct = struct
      # Default attributes:
      @beams = Array.new
      @rt_doses = Array.new
      @rt_images = Array.new
      @associated_rt_doses = Hash.new
      # Register ourselves with the StructureSet:
      @struct.add_plan(self)
    end

    # Returns true if the argument is an instance with attributes equal to self.
    #
    def ==(other)
      if other.respond_to?(:to_plan)
        other.send(:state) == state
      end
    end

    alias_method :eql?, :==

    # Registers a DICOM Object to the Plan, and processes it
    # to create (and reference) the fields contained in the object.
    #
    def add(dcm)
      raise ArgumentError, "Invalid argument 'dcm'. Expected DObject, got #{dcm.class}." unless dcm.is_a?(DICOM::DObject)
      @dcm = dcm
      #load_patient_setup
      load_beams
    end

    # Adds a Beam to this Plan.
    # Note: Intended for internal use in the library only.
    #
    def add_beam(beam)
      raise ArgumentError, "Invalid argument 'beam'. Expected Beam, got #{beam.class}." unless beam.is_a?(Beam)
      @beams << beam unless @beams.include?(beam)
    end

    # Adds a RTDose series to this Plan.
    # Note: Intended for internal use in the library only.
    #
    def add_rt_dose(rt_dose)
      raise ArgumentError, "Invalid argument 'rt_dose'. Expected RTDose, got #{rt_dose.class}." unless rt_dose.is_a?(RTDose)
      @rt_doses << rt_dose unless @associated_rt_doses[rt_dose.uid]
      @associated_rt_doses[rt_dose.uid] = rt_dose
    end

    # Adds a RTImage Series to this Plan.
    # Note: Intended for internal use in the library only.
    #
    def add_rt_image(rt_image)
      raise ArgumentError, "Invalid argument 'rt_image'. Expected RTImage, got #{rt_image.class}." unless rt_image.is_a?(RTImage)
      @rt_images << rt_image unless @rt_images.include?(rt_image)
    end

    # Sets the Setup reference for this Plan.
    # Note: Intended for internal use in the library only.
    #
    def add_setup(setup)
      raise ArgumentError, "Invalid argument 'setup'. Expected Setup, got #{setup.class}." unless setup.is_a?(Setup)
      @setup = setup
    end

    # Generates a Fixnum hash value for this instance.
    #
    def hash
      state.hash
    end

    # Returns the RTDose instance mathcing the specified Series Instance UID (if an argument is used).
    # If a specified UID doesn't match, nil is returned.
    # If no argument is passed, the first RTDose instance associated with the Plan is returned.
    #
    # === Parameters
    #
    # * <tt>uid</tt> -- String. The value of the Series Instance UID element.
    #
    def rt_dose(*args)
      raise ArgumentError, "Expected one or none arguments, got #{args.length}." unless [0, 1].include?(args.length)
      if args.length == 1
        raise ArgumentError, "Expected String (or nil), got #{args.first.class}." unless [String, NilClass].include?(args.first.class)
        return @associated_rt_doses[args.first]
      else
        # No argument used, therefore we return the first RTDose instance:
        return @rt_doses.first
      end
    end

    # Returns self.
    #
    def to_plan
      self
    end


    private


=begin
    # Registers this Plan instance with the StructureSet(s) that it references.
    #
    def connect_to_struct
      # Find out which Structure Set is referenced:
      @dcm[REF_STRUCT_SQ].each do |struct_item|
        ref_sop_uid = struct_item.value(REF_SOP_UID)
        matched_struct = @study.associated_instance_uids[ref_sop_uid]
        if matched_struct
          # The referenced series exists in our dataset. Proceed with setting up the references:
          matched_struct.add_plan(self)
          @structs << matched_struct
          @stuct = matched_struct unless @struct
        end
      end
    end
=end

    # Loads the Beam Items contained in the RTPlan and creates Beam instances.
    #
    def load_beams
      # Load the patient position.
      # NB! (FIXME) We assume that there is only one patient setup sequence item!
      Setup.create_from_item(@dcm[PATIENT_SETUP_SQ][0], self)
      # Load the information in a nested hash:
      item_group = Hash.new
      # NB! (FIXME) We assume there is only one fraction group!
      @dcm[FRACTION_GROUP_SQ][0][REF_BEAM_SQ].each do |fg_item|
        item_group[fg_item.value(REF_BEAM_NUMBER)] = {:meterset => fg_item.value(BEAM_METERSET).to_f}
      end
      @dcm[BEAM_SQ].each do |beam_item|
        item_group[beam_item.value(BEAM_NUMBER)][:beam] = beam_item
      end
      # Create a Beam instance for each set of items:
      item_group.each_value do |beam_items|
        Beam.create_from_item(beam_items[:beam], beam_items[:meterset], self)
      end
    end

    # Returns the attributes of this instance in an array (for comparison purposes).
    #
    def state
       [@beams, @patient_position, @rt_doses, @rt_images, @setup, @sop_uid]
    end

  end
end