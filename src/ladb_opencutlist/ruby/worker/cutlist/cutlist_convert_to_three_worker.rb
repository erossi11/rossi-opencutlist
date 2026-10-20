module Ladb::OpenCutList

  require_relative '../../helper/layer_visibility_helper'
  require_relative '../../helper/hashable_helper'
  require_relative '../../utils/axis_utils'
  require_relative '../../model/attributes/material_attributes'
  require_relative '../../model/formula/formula_data'
  require_relative '../../worker/common/common_eval_formula_worker'

  class CutlistConvertToThreeWorker

    include LayerVisibilityHelper

    def initialize(parts,

                   all_instances: false,
                   parts_colored: true,
                   pins_formula: ''

    )

      @parts = parts

      @all_instances = all_instances
      @parts_colored = parts_colored
      @pins_formula = pins_formula

    end

    # -----

    def run
      return nil if Sketchup.version_number < 1800000000

      model = Sketchup.active_model
      return nil unless model

      materials = model.materials

      active_path = model.active_path.nil? ? [] : model.active_path
      active_entity = active_path.last

      three_model_def = ThreeModelDef.new

      group_cache = {}  # key = serialized_path, value = group - Only for all instances

      @parts.each do |part|

        if @all_instances

          # Setup model matrix to be able to "align on active view axes"
          three_model_def.matrix = _to_three_matrix(model.edit_transform.inverse)

          part.def.instance_infos.each do |serialized_path, instance_info|

            # Populate part definitions
            _create_three_part_def(three_model_def, part, instance_info.entity.definition, materials[part.material_name])

            # Create the three part instance def
            three_part_instance_def = ThreePartInstanceDef.new
            three_part_instance_def.matrix = _to_three_matrix(instance_info.entity.transformation)
            three_part_instance_def.id = part.id
            three_part_instance_def.runtime_index = three_model_def.part_instance_count
            three_part_instance_def.persistent_id = instance_info.persistent_id
            three_part_instance_def.persistent_id_path = instance_info.persistent_id_path
            three_part_instance_def.part_number = part.number
            three_part_instance_def.material_name = part.material_name
            three_part_instance_def.length = part.length.to_s.to_l.to_mm.round(2)
            three_part_instance_def.width = part.width.to_s.to_l.to_mm.round(2)
            three_part_instance_def.thickness = part.thickness.to_s.to_l.to_mm.round(2)
            three_part_instance_def.text = _evaluate_text(InstanceData.new(

              number: StringFormulaWrapper.new(part.number),
              path: ArrayFormulaWrapper.new(PathUtils.get_named_path(instance_info.path, true, 1)),
              instance_name: StringFormulaWrapper.new(instance_info.entity.name),
              name: StringFormulaWrapper.new(part.name),
              cutting_length: LengthFormulaWrapper.new(part.def.cutting_length),
              cutting_width: LengthFormulaWrapper.new(part.def.cutting_width),
              cutting_thickness: LengthFormulaWrapper.new(part.def.cutting_size.thickness),
              edge_cutting_length: LengthFormulaWrapper.new(part.def.edge_cutting_length),
              edge_cutting_width: LengthFormulaWrapper.new(part.def.edge_cutting_width),
              bbox_length: LengthFormulaWrapper.new(part.def.size.length),
              bbox_width: LengthFormulaWrapper.new(part.def.size.width),
              bbox_thickness: LengthFormulaWrapper.new(part.def.size.thickness),
              final_area: AreaFormulaWrapper.new(part.def.final_area),
              material: MaterialFormulaWrapper.new(part.group.def.material, part.group.def),
              description: StringFormulaWrapper.new(part.description),
              url: StringFormulaWrapper.new(part.url),
              tags: ArrayFormulaWrapper.new(part.tags),
              edge_ymin: EdgeFormulaWrapper.new(part.def.edge_materials[:ymin], part.def.edge_group_defs[:ymin]),
              edge_ymax: EdgeFormulaWrapper.new(part.def.edge_materials[:ymax], part.def.edge_group_defs[:ymax]),
              edge_xmin: EdgeFormulaWrapper.new(part.def.edge_materials[:xmin], part.def.edge_group_defs[:xmin]),
              edge_xmax: EdgeFormulaWrapper.new(part.def.edge_materials[:xmax], part.def.edge_group_defs[:xmax]),
              face_zmin: VeneerFormulaWrapper.new(part.def.veneer_materials[:zmin], part.def.veneer_group_defs[:zmin]),
              face_zmax: VeneerFormulaWrapper.new(part.def.veneer_materials[:zmax], part.def.veneer_group_defs[:zmax]),
              layer: StringFormulaWrapper.new(instance_info.layer.name),

              component_definition: ComponentDefinitionFormulaWrapper.new(instance_info.definition),
              component_instance: ComponentInstanceFormulaWrapper.new(instance_info.entity),

            ))

            # Add to hierarchy
            parent_three_group_def = _parent_hierarchy(instance_info.path[0...-1], active_entity, group_cache, three_model_def)
            parent_three_group_def.add(three_part_instance_def)

            # Increment model part instance count
            three_model_def.part_instance_count += 1

          end

        else

          # Extract first instance
          instance_info = part.def.get_one_instance_info

          # Populate part definitions
          _create_three_part_def(three_model_def, part, instance_info.entity.definition, materials[part.material_name])

          mt = Geom::Transformation.new
          if part.auto_oriented && part.group.material_type != MaterialAttributes::TYPE_HARDWARE

            # Set model matrix to put length axis along X, width along Y and thickness along Z to display the part always in the same direction even if it is auto oriented
            mt = part.def.size.oriented_transformation.inverse
            three_model_def.matrix = _to_three_matrix(mt)

          end

          # Extract instance transformation
          it = instance_info.transformation

          # Extract scale values
          scale = part.def.scale.clone
          scale.x *= -1 if TransformationUtils.flipped?(it) ^ part.def.size.axes_flipped?

          # Create a scale only transformation
          ist = Geom::Transformation.scaling(scale.x, scale.y, scale.z)

          irt = Geom::Transformation.new
          if scale.x < 0
            if part.def.size.oriented_axis(Z_AXIS) == X_AXIS
              # Applies a 180° rotation along the width axis if the part is flipped thicknesswise to force front face to be rendered on top
              irt *= Geom::Transformation.rotation(ORIGIN, part.def.size.oriented_axis(Y_AXIS), 180.degrees)
            end
            if part.def.size.oriented_axis(Y_AXIS) == X_AXIS
              # Applies a 180° rotation along the thickness axis if the part is flipped lengthwise to force the origin to be rendered away
              irt *= Geom::Transformation.rotation(ORIGIN, part.def.size.oriented_axis(Z_AXIS), 180.degrees)
            end
          end

          # Setup model axes matrix
          three_model_def.axes_matrix = _to_three_matrix(mt * ist * irt)

          # Create the three part instance def
          three_part_instance_def = ThreePartInstanceDef.new
          three_part_instance_def.matrix = _to_three_matrix(ist * irt)
          three_part_instance_def.id = part.id

          # Add to hierarchy
          three_model_def.add(three_part_instance_def)

          # Increment model part instance count
          three_model_def.part_instance_count += 1

          # Extract bounding box dims
          unless part.group.material_type == MaterialAttributes::TYPE_HARDWARE
            three_model_def.x_dim = "#{PLUGIN.get_i18n_string('tab.cutlist.list.length_short')} = #{part.length}"
            three_model_def.y_dim = "#{PLUGIN.get_i18n_string('tab.cutlist.list.width_short')} = #{part.width}"
            three_model_def.z_dim = "#{PLUGIN.get_i18n_string('tab.cutlist.list.thickness_short')} = #{part.thickness}"
          end

        end

      end

      # _dump(three_model_def)

      three_model_def
    end

    # -----

    private

    def _evaluate_text(data)
      formula = @pins_formula.is_a?(String) && !@pins_formula.empty? ? @pins_formula : '@number'
      CommonEvalFormulaWorker.new(formula: formula, data: data).run
    end

    def _create_three_part_def(three_model_def, part, definition, material)

      three_part_def = three_model_def.part_defs.fetch(part.id, nil)
      if three_part_def.nil?

        three_part_def = ThreePartDef.new
        three_part_def.face_vertices,
        three_part_def.face_colors,
        three_part_def.face_uvs,
        three_part_def.face_groups,
        three_part_def.hard_edge_vertices,
        three_part_def.soft_edge_vertices,
        three_part_def.soft_edge_controls0,
        three_part_def.soft_edge_controls1,
        three_part_def.soft_edge_directions = _grab_entities_vertices_and_colors(definition.entities, material, nil, three_model_def)
        three_part_def.color = _to_three_color(material)
        three_part_def.material_name = material.is_a?(Sketchup::Material) ? material.name : nil

        # Sin ningún face_group texturado no hay UVs útiles en esta pieza - se
        # descarta el array entero (en vez de mandar puros ceros) para no
        # engordar el payload de proyectos sin materiales texturados.
        three_part_def.face_uvs = [] unless three_part_def.face_groups.any? { |g| g[:textured] }
        three_part_def.face_groups.each { |g| g.delete(:textured) }

        three_model_def.part_defs.store(part.id, three_part_def)
      end

    end

    # three_model_def: se necesita durante toda la recursión para poder registrar
    # (_register_material_texture) la textura de CUALQUIER material que aparezca
    # en cualquier cara, no solo el material "de referencia" de la pieza - los
    # cantos/caras pintadas individualmente (con un material propio, ej. canto
    # blanco) ahora arman su propio grupo de geometría con su propio color o
    # textura real, en vez de heredar/mancharse con la textura de la cara
    # principal (bug detectado en vivo: cantos blancos aparecían negros).
    def _grab_entities_vertices_and_colors(entities, material, transformation = nil, three_model_def = nil)
      face_vertices = []
      face_colors = []
      face_uvs = []
      face_groups = []
      hard_edge_vertices = []
      soft_edge_vertices = []
      soft_edge_controls0 = []
      soft_edge_controls1 = []
      soft_edge_directions = []
      entities.each do |entity|

        next unless entity.visible? && _layer_visible?(entity.layer)

        if entity.is_a?(Sketchup::Face)
          fv, fc, fu, fg = _grab_face_vertices_and_colors(entity, material, transformation, three_model_def)
          fg[:start] = face_vertices.length / 3
          face_vertices.concat(fv)
          face_colors.concat(fc)
          face_uvs.concat(fu)
          face_groups.push(fg)
        elsif entity.is_a?(Sketchup::Edge)
          hev, sev, sec0, sec1, dir = _grab_edge_vertices_and_controls(entity, transformation)
          hard_edge_vertices.concat(hev)
          soft_edge_vertices.concat(sev)
          soft_edge_controls0.concat(sec0)
          soft_edge_controls1.concat(sec1)
          soft_edge_directions.concat(dir)
        elsif entity.is_a?(Sketchup::Group)
          fv, fc, fu, fg_list, hev, sev, sec0, sec1, dir = _grab_entities_vertices_and_colors(entity.entities, entity.material.nil? ? material : entity.material, TransformationUtils::multiply(transformation, entity.transformation), three_model_def)
          offset = face_vertices.length / 3
          fg_list.each { |g| g[:start] += offset }
          face_vertices.concat(fv)
          face_colors.concat(fc)
          face_uvs.concat(fu)
          face_groups.concat(fg_list)
          hard_edge_vertices.concat(hev)
          soft_edge_vertices.concat(sev)
          soft_edge_controls0.concat(sec0)
          soft_edge_controls1.concat(sec1)
          soft_edge_directions.concat(dir)
        elsif entity.is_a?(Sketchup::ComponentInstance) && entity.definition.behavior.cuts_opening?
          fv, fc, fu, fg_list, hev, sev, sec0, sec1, dir = _grab_entities_vertices_and_colors(entity.definition.entities, entity.material.nil? ? material : entity.material, TransformationUtils::multiply(transformation, entity.transformation), three_model_def)
          offset = face_vertices.length / 3
          fg_list.each { |g| g[:start] += offset }
          face_vertices.concat(fv)
          face_colors.concat(fc)
          face_uvs.concat(fu)
          face_groups.concat(fg_list)
          hard_edge_vertices.concat(hev)
          soft_edge_vertices.concat(sev)
          soft_edge_controls0.concat(sec0)
          soft_edge_controls1.concat(sec1)
          soft_edge_directions.concat(dir)
        end

      end

      [ face_vertices, face_colors, face_uvs, face_groups, hard_edge_vertices, soft_edge_vertices, soft_edge_controls0, soft_edge_controls1, soft_edge_directions ]
    end

    def _grab_face_vertices_and_colors(face, material, transformation = nil, three_model_def = nil)

      effective_material = face.material.nil? ? material : face.material

      # Se capturan UVs (para poder texturar) en CUALQUIER cara cuyo material
      # efectivo tenga una textura real asignada - ya no se restringe al
      # material "de referencia" de la pieza, porque ahora cada material
      # distinto arma su propio grupo de geometría con su propia textura/color
      # (ver face_groups). Se registra la textura de este material puntual
      # (deduplicado por nombre, no-op si ya está registrado o no tiene textura).
      capture_uv = effective_material.is_a?(Sketchup::Material) && !effective_material.texture.nil?
      _register_material_texture(three_model_def, effective_material) if three_model_def

      mesh = face.mesh(capture_uv ? 1 : 0) # POLYGON_MESH_POINTS | POLYGON_MESH_UVQ_FRONT
      points = mesh.points
      points.each { |point| point.transform!(transformation) } unless transformation.nil?

      red, green, blue = _to_three_vertex_color(effective_material)

      vertices = []
      colors = []
      uvs = []
      mesh.polygons.each { |polygon|
        polygon.each { |index|

          point = points[index.abs - 1]
          vertices << point.x.to_f
          vertices << point.y.to_f
          vertices << point.z.to_f

          if @parts_colored
            colors << red
            colors << green
            colors << blue
          end

          # Siempre se empuja un par (u, v) - aunque sea (0, 0) cuando esta cara
          # puntual no captura UV - para que face_uvs quede 1:1 alineado con
          # face_vertices dentro de la malla combinada de toda la pieza (si una
          # cara con material distinto no empujara nada, correría/desalinearía
          # las UVs de todas las caras siguientes).
          if capture_uv
            uvq = mesh.uv_at(index.abs, true)
            q = uvq.z
            uvs << (q != 0 ? uvq.x / q : uvq.x)
            uvs << (q != 0 ? uvq.y / q : uvq.y)
          else
            uvs << 0.0
            uvs << 0.0
          end

        }
      }

      # :start se completa en el caller (_grab_entities_vertices_and_colors),
      # acá todavía no se sabe el offset dentro del buffer combinado de la pieza.
      # :textured es temporal, se usa solo para decidir si conviene descartar
      # face_uvs entero en _create_three_part_def, y se borra antes de serializar.
      group = {
        material_name: effective_material.is_a?(Sketchup::Material) ? effective_material.name : nil,
        color: _to_three_color(effective_material),
        start: 0,
        count: vertices.length / 3,
        textured: capture_uv
      }

      [ vertices, colors, uvs, group ]
    end

    def _grab_edge_vertices_and_controls(edge, transformation = nil)
      hard_vertices = []
      soft_vertices = []
      soft_controls0 = []
      soft_controls1 = []
      soft_directions = []

      unless edge.faces.empty?  # Exclude edges not connected to a face

        # Soft controls
        if edge.soft?

          edge.faces.each do |face|

            vertex = face.vertices.find { |v| !edge.used_by?(v) }
            if vertex.is_a?(Sketchup::Vertex)

              point = vertex.position
              point.transform!(transformation) unless transformation.nil?

              # Inspired from LDraw specification : https://www.ldraw.org/article/218.html#lt5
              controls = soft_controls0.empty? ? soft_controls0 : soft_controls1
              2.times do
                controls << point.x.to_f
                controls << point.y.to_f
                controls << point.z.to_f
              end

            end

            unless soft_controls0.empty? || soft_controls1.empty?
              break
            end

          end

          # Check if there's enough controls
          if soft_controls0.empty? || soft_controls1.empty?
            soft_controls0.clear
            soft_controls1.clear
          end

        end

        # Vertices
        edge.vertices.each do |vertex|

          point = vertex.position
          point.transform!(transformation) unless transformation.nil?

          vertices = soft_controls0.empty? ? hard_vertices : soft_vertices
          vertices << point.x.to_f
          vertices << point.y.to_f
          vertices << point.z.to_f

        end

        # Soft directions
        unless soft_controls0.empty?
          2.times do
            soft_directions << soft_vertices[3] - soft_vertices[0]
            soft_directions << soft_vertices[4] - soft_vertices[1]
            soft_directions << soft_vertices[5] - soft_vertices[2]
          end
        end

      end

      [ hard_vertices, soft_vertices, soft_controls0, soft_controls1, soft_directions ]
    end

    def _parent_hierarchy(path, active_entity, cache, three_model_def)
      return three_model_def if path.nil? || path.empty?
      return three_model_def if path.last == active_entity

      serialized_path = PathUtils.serialize_path(path)

      # Pop last path entity
      entity = path.pop

      # Try to fetch three group def from cache
      three_group_def = cache.fetch(serialized_path, nil)
      unless three_group_def

        # Create a new three group def
        three_group_def = ThreeGroupDef.new
        three_group_def.name = entity.name
        three_group_def.matrix = _to_three_matrix(entity.transformation)

        # Keep it in the cache
        cache.store(serialized_path, three_group_def)

        # Try to retrieve parent
        parent_three_group_def = _parent_hierarchy(path, active_entity, cache, three_model_def)
        if parent_three_group_def
          # Parent found, add current group as child
          parent_three_group_def.add(three_group_def)
        else
          # No more parent, add current group to model
          three_model_def.add(three_group_def)
        end

      end

      three_group_def
    end

    def _to_three_matrix(tranformation)
      return nil unless tranformation.is_a?(Geom::Transformation)
      # return nil if tranformation.identity?
      tranformation.to_a.flatten
    end

    def _to_three_color(material)
      return nil unless material.is_a?(Sketchup::Material)
      (material.color.red << 16) + (material.color.green << 8) + material.color.blue
    end

    def _to_three_vertex_color(material)
      return [ 1, 1, 1 ] unless material.is_a?(Sketchup::Material)
      [ material.color.red / 255.0, material.color.green / 255.0, material.color.blue / 255.0 ]
    end

    # Registra (una sola vez por nombre de material, deduplicado) la imagen de
    # textura real como data URI base64 en three_model_def.textures. No se
    # transporta por-instancia ni por-parte: todas las ThreePartDef que usan el
    # mismo material comparten la misma entrada acá (mismo criterio de reuso
    # que ya aplica part_defs para la geometría).
    def _register_material_texture(three_model_def, material)
      return unless material.is_a?(Sketchup::Material) && material.texture
      return if three_model_def.textures.key?(material.name)

      data_uri = _texture_to_data_uri(material.texture)
      return if data_uri.nil?

      three_model_def.textures[material.name] = {
        data_uri: data_uri,
        width: material.texture.width.to_f,   # pulgadas, tamaño real del tile de textura
        height: material.texture.height.to_f
      }
    end

    def _texture_to_data_uri(texture)
      temp_dir = File.join(PLUGIN.temp_dir, 'material_textures_export')
      Dir.mkdir(temp_dir) unless Dir.exist?(temp_dir)

      texture_file = File.join(temp_dir, "#{SecureRandom.uuid}.png")

      begin
        texture.write(texture_file)
        return nil unless File.exist?(texture_file)

        "data:image/png;base64,#{Base64.strict_encode64(File.binread(texture_file))}"
      ensure
        File.delete(texture_file) if File.exist?(texture_file)
      end
    rescue StandardError
      nil
    end

    def _dump(three_object_def, level = 1)
      puts "#{'+'.rjust(level, '-')}#{three_object_def.class.to_s} #{three_object_def.name} #{(three_object_def.is_a?(ThreePartInstanceDef) ? three_object_def.id.to_s : '')}"
      if three_object_def.is_a?(ThreeModelDef)
        three_object_def.part_defs.each do |id, part_def|
          puts "@ #{id} - (#{part_def.number}) #{part_def.name}"
        end
      end
      if three_object_def.is_a?(ThreeGroupDef)
        _dump_matrix(three_object_def.matrix, level)
        three_object_def.children.each do |child_three_object_def|
          _dump(child_three_object_def, level + 1)
        end
      end
    end

    def _dump_matrix(matrix, level)
      matrix = _to_three_matrix(Geom::Transformation.new) if matrix.nil?
      puts "#{'+'.rjust(level, ' ')} #{matrix[0].round(1)} #{matrix[4].round(1)} #{matrix[8].round(1)} #{matrix[12].round(1)}"
      puts "#{'+'.rjust(level, ' ')} #{matrix[1].round(1)} #{matrix[5].round(1)} #{matrix[9].round(1)} #{matrix[13].round(1)}"
      puts "#{'+'.rjust(level, ' ')} #{matrix[2].round(1)} #{matrix[6].round(1)} #{matrix[10].round(1)} #{matrix[14].round(1)}"
      puts "#{'+'.rjust(level, ' ')} #{matrix[3].round(1)} #{matrix[7].round(1)} #{matrix[11].round(1)} #{matrix[15].round(1)}"
    end

    def _separate_translation_scaling_rotation(transformation)

      m = transformation.to_a

      m = m.clone

      # Extract translation
      translation = m.values_at(12, 13, 14)

      # Extract scaling, considering uniform scale factor (last matrix element)
      scaling = Array.new(3)
      scaling[0] = m[15] * Math.sqrt(m[0]**2 + m[1]**2 + m[2]**2)
      scaling[1] = m[15] * Math.sqrt(m[4]**2 + m[5]**2 + m[6]**2)
      scaling[2] = m[15] * Math.sqrt(m[8]**2 + m[9]**2 + m[10]**2)
      # Remove scaling to prepare for extraction of rotation
      [0, 1, 2].each{ |i| m[i] /= scaling[0] } unless scaling[0] == 0.0
      [4, 5, 6].each{ |i| m[i] /= scaling[1] } unless scaling[1] == 0.0
      [8, 9,10].each{ |i| m[i] /= scaling[2] } unless scaling[2] == 0.0
      m[15] = 1.0
      # Verify orientation, if necessary invert it.
      tmp_z_axis = Geom::Vector3d.new(m[0], m[1], m[2]).cross(Geom::Vector3d.new(m[4], m[5], m[6]))
      if tmp_z_axis.dot( Geom::Vector3d.new(m[8], m[9], m[10]) ) < 0
        scaling[0] *= -1
        m[0] = -m[0]
        m[1] = -m[1]
        m[2] = -m[2]
      end

      # Extract rotation
      # Source: Extracting Euler Angles from a Rotation Matrix, Mike Day, Insomniac Games
      # http://www.insomniacgames.com/mike-day-extracting-euler-angles-from-a-rotation-matrix/
      theta1 = Math.atan2(m[6], m[10])
      c2 = Math.sqrt(m[0]**2 + m[1]**2)
      theta2 = Math.atan2(-m[2], c2)
      s1 = Math.sin(theta1)
      c1 = Math.cos(theta1)
      theta3 = Math.atan2(s1*m[8] - c1*m[4], c1*m[5] - s1*m[9])
      rotation = [-theta1, -theta2, -theta3]

      [ translation, scaling, rotation ]
    end

  end

  # -----

  class ThreePartDef

    include HashableHelper

    attr_accessor :face_vertices, :face_colors, :face_uvs, :face_groups, :hard_edge_vertices, :soft_edge_vertices, :soft_edge_controls0, :soft_edge_controls1, :soft_edge_directions, :text, :color, :material_name

    def initialize
      @face_vertices = []
      @face_colors = []
      @face_uvs = []
      @face_groups = []
      @material_name = nil
      @hard_edge_vertices = []
      @soft_edge_vertices = []
      @soft_edge_controls0 = []
      @soft_edge_controls1 = []
      @soft_edge_directions = []
      @color = nil
    end

  end

  class ThreeObjectDef

    include HashableHelper

    TYPE_UNDEFINED = 0
    TYPE_MODEL = 1
    TYPE_GROUP = 2
    TYPE_PART_INSTANCE = 3

    attr_accessor :name

    def initialize(type = TYPE_UNDEFINED)
      @type = type
      @name = ''
    end

    def type
      @type
    end

  end

  class ThreeGroupDef < ThreeObjectDef

    attr_accessor :matrix
    attr_reader :children

    def initialize(type = ThreeObjectDef::TYPE_GROUP)
      super(type)
      @matrix = nil
      @children = []
    end

    def add(three_object)
      @children.push(three_object)
    end

  end

  class ThreeModelDef < ThreeGroupDef

    attr_accessor :part_instance_count, :axes_matrix, :x_dim, :y_dim, :z_dim
    attr_reader :part_defs, :textures

    def initialize
      super(ThreeObjectDef::TYPE_MODEL)
      @part_defs = {}
      @textures = {}   # material_name => { data_uri:, width:, height: } - deduplicado, ver _register_material_texture
      @part_instance_count = 0
      @axes_matrix = nil
      @x_dim = nil
      @y_dim = nil
      @z_dim = nil
    end

  end

  class ThreePartInstanceDef < ThreeGroupDef

    attr_accessor :id, :text, :runtime_index, :persistent_id, :persistent_id_path, :part_number, :material_name, :length, :width, :thickness

    def initialize
      super(ThreeObjectDef::TYPE_PART_INSTANCE)
      @id = nil
      @text = nil
      @runtime_index = nil
      @persistent_id = nil
      @persistent_id_path = nil
      @part_number = nil
      @material_name = nil
      @length = nil
      @width = nil
      @thickness = nil
    end

  end

  # -----

  class InstanceData < FormulaData

    def initialize(

      number:,
      path:,
      instance_name:,
      name:,
      cutting_length:,
      cutting_width:,
      cutting_thickness:,
      edge_cutting_length:,
      edge_cutting_width:,
      bbox_length:,
      bbox_width:,
      bbox_thickness:,
      final_area:,
      material:,
      description:,
      url:,
      tags:,
      edge_ymin:,
      edge_ymax:,
      edge_xmin:,
      edge_xmax:,
      face_zmin:,
      face_zmax:,
      layer:,

      component_definition:,
      component_instance:

    )

      @number = number
      @path = path
      @instance_name = instance_name
      @name = name
      @cutting_length = cutting_length
      @cutting_width = cutting_width
      @cutting_thickness = cutting_thickness
      @edge_cutting_length = edge_cutting_length
      @edge_cutting_width = edge_cutting_width
      @bbox_length = bbox_length
      @bbox_width = bbox_width
      @bbox_thickness = bbox_thickness
      @final_area = final_area
      @material = material
      @material_type = material.type
      @material_name = material.name
      @material_description = material.description
      @material_url = material.url
      @description = description
      @url = url
      @tags = tags
      @edge_ymin = edge_ymin
      @edge_ymax = edge_ymax
      @edge_xmin = edge_xmin
      @edge_xmax = edge_xmax
      @face_zmin = face_zmin
      @face_zmax = face_zmax
      @layer = layer

      @component_definition = component_definition
      @component_instance = component_instance

    end

  end

end