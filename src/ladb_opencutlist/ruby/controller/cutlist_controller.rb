module Ladb::OpenCutList

  require_relative 'controller'
  require_relative '../model/attributes/material_attributes'
  require_relative '../model/attributes/definition_attributes'
  require_relative '../observer/app_observer'
  require_relative '../observer/selection_observer'
  require_relative '../observer/materials_observer'
  require_relative '../observer/model_observer'
  require_relative '../lib/fiddle/packy/packy'
  require 'json'
  require 'net/http'
  require 'uri'

  Packy = Fiddle::Packy

  class CutlistController < Controller

    def initialize()
      super('cutlist')

      @rossi_payload_pendiente = nil
      @rossi_project_payload_pendiente = nil
    end

    def setup_commands

      # Setup opencutlist dialog actions
      PLUGIN.register_command("cutlist_generate") do |settings|
        generate_command(settings)
      end

      PLUGIN.register_command("cutlist_export_rossi") do
        export_rossi_command
      end

      PLUGIN.register_command("cutlist_export_rossi_confirm") do
        export_rossi_confirm_command
      end

      PLUGIN.register_command("cutlist_export_project") do
        export_project_command
      end

      PLUGIN.register_command("cutlist_export_project_select_mueble") do |params|
        export_project_select_mueble_command(params)
      end

      PLUGIN.register_command("cutlist_export_project_confirm") do |params|
        export_project_confirm_command(params)
      end

      PLUGIN.register_command("cutlist_add_to_rossi_series") do
        add_to_rossi_series_command
      end

      PLUGIN.register_command("cutlist_export") do |settings|
        export_command(settings)
      end

      PLUGIN.register_command("cutlist_estimate_start") do |settings|
        estimate_start_command(settings)
      end

      PLUGIN.register_command("cutlist_estimate_advance") do |settings|
        estimate_advance_command
      end

      PLUGIN.register_command("cutlist_estimate_next") do |settings|
        estimate_next_command
      end

      PLUGIN.register_command("cutlist_estimate_cancel") do |settings|
        estimate_cancel_command
      end

      PLUGIN.register_command("cutlist_numbers_save") do |settings|
        numbers_command(settings, false)
      end

      PLUGIN.register_command("cutlist_numbers_reset") do |settings|
        numbers_command(settings, true)
      end

      PLUGIN.register_command("cutlist_highlight_parts") do |settings|
        highlight_parts_command(settings)
      end

      PLUGIN.register_command("cutlist_layout_parts") do |settings|
        layout_parts_command(settings)
      end

      PLUGIN.register_command("cutlist_layout_to_layout") do |settings|
        layout_to_layout_command(settings)
      end

      PLUGIN.register_command("cutlist_part_get_thumbnail") do |part_data|
        part_get_thumbnail_command(part_data)
      end

      PLUGIN.register_command("cutlist_part_update") do |settings|
        part_update_command(settings)
      end

      PLUGIN.register_command("cutlist_write_parts") do |settings|
        write_parts_command(settings)
      end

      PLUGIN.register_command("cutlist_group_cuttingdiagram1d_start") do |settings|
        group_cuttingdiagram1d_start_command(settings)
      end

      PLUGIN.register_command("cutlist_group_cuttingdiagram1d_advance") do
        group_cuttingdiagram1d_advance_command
      end

      PLUGIN.register_command("cutlist_cuttingdiagram1d_write") do |settings|
        cuttingdiagram1d_write_command(settings)
      end

      PLUGIN.register_command("cutlist_group_cuttingdiagram2d_start") do |settings|
        group_cuttingdiagram2d_start_command(settings)
      end

      PLUGIN.register_command("cutlist_group_cuttingdiagram2d_advance") do
        group_cuttingdiagram2d_advance_command
      end

      PLUGIN.register_command("cutlist_cuttingdiagram2d_write") do |settings|
        cuttingdiagram2d_write_command(settings)
      end

      PLUGIN.register_command("cutlist_labels") do |settings|
        labels_command(settings)
      end

      PLUGIN.register_command("cutlist_reset_prices") do
        reset_prices_command
      end


      PLUGIN.register_command("cutlist_group_packing_start") do |settings|
        group_packing_start_command(settings)
      end

      PLUGIN.register_command("cutlist_group_packing_advance") do
        group_packing_advance_command
      end

      PLUGIN.register_command("cutlist_group_packing_cancel") do
        group_packing_cancel_command
      end

      PLUGIN.register_command("cutlist_packing_write") do |settings|
        packing_write_command(settings)
      end

    end

    def setup_event_callbacks

      PLUGIN.add_event_callback([
                                   AppObserver::ON_NEW_MODEL,
                                   AppObserver::ON_OPEN_MODEL,
                                   AppObserver::ON_ACTIVATE_MODEL,
                                   SelectionObserver::ON_SELECTION_BULK_CHANGE,
                                   SelectionObserver::ON_SELECTION_CLEARED,
                                   MaterialsObserver::ON_MATERIAL_CHANGE,
                                   MaterialsObserver::ON_MATERIAL_REMOVE,
                                   ModelObserver::ON_DRAWING_CHANGE,
                               ]) do |params|

        # Invalidate Cutlist if it exists
        @cutlist.invalidate if @cutlist

      end

      PLUGIN.add_event_callback([
                                  AppObserver::ON_QUIT,
                                  'on_tabs_dialog_close',
                                  'on_tabs_dialog_minimized'
                                ]) do |params|

        # Cancel all Packy runs
        Packy.optimize_cancel_all

      end
    end

    private

    # -- Commands --


    def export_rossi_command
      unless @cutlist
        UI.messagebox('Primero debe generar el listado de partes.')

        return {
          ok: false,
          error: 'cutlist_not_generated'
        }
      end

      datos_presupuesto = solicitar_datos_presupuesto

      return {
        ok: false,
        cancelled: true
      } unless datos_presupuesto

      cutlist_hash = @cutlist.to_hash

      calcular_cortes_placas_async(
        cutlist_hash,
        datos_presupuesto
      )

      {
        ok: true,
        processing: true
      }
    end

    def export_rossi_confirm_command
      unless @rossi_payload_pendiente
        return {
          ok: false,
          error: 'no_pending_payload'
        }
      end

      # Se toma y se limpia de inmediato: salvaguarda barata contra
      # doble-click / doble confirmación reinsertando el mismo mueble.
      payload = @rossi_payload_pendiente.merge(
        confirmar_solo_reconocidos: true
      )
      @rossi_payload_pendiente = nil

      enviar_post_rossi(payload)

      {
        ok: true,
        processing: true
      }
    end

    def export_project_command
      unless @cutlist
        UI.messagebox('Primero debe generar el listado de partes.')

        return {
          ok: false,
          error: 'cutlist_not_generated'
        }
      end

      id_proyecto = solicitar_numero_proyecto

      return {
        ok: false,
        cancelled: true
      } unless id_proyecto

      listar_muebles_proyecto_rossi_async(id_proyecto)

      {
        ok: true,
        processing: true
      }
    end

    def export_project_select_mueble_command(params)
      unless @cutlist
        UI.messagebox('Primero debe generar el listado de partes.')

        return {
          ok: false,
          error: 'cutlist_not_generated'
        }
      end

      id_proyecto = params[:id_proyecto].to_s.strip
      id_mueble = params[:id_mueble].to_s.strip

      return {
        ok: false,
        error: 'missing_params'
      } if id_proyecto.empty? || id_mueble.empty?

      cutlist_hash = @cutlist.to_hash

      rossi_project_payload = {
        schema_version: '1.0',
        source: 'opencutlist',
        id_proyecto: id_proyecto,
        id_mueble: id_mueble,
        filename: cutlist_hash[:filename] || cutlist_hash['filename'],
        materiales: build_rossi_project_materiales(cutlist_hash)
      }

      puts 'ROSSI PROJECT: payload final'
      puts JSON.pretty_generate(rossi_project_payload)

      @rossi_project_payload_pendiente = rossi_project_payload

      enviar_post_rossi_project(rossi_project_payload)

      {
        ok: true,
        processing: true
      }
    end

    def export_project_confirm_command(params)
      unless @rossi_project_payload_pendiente
        return {
          ok: false,
          error: 'no_pending_payload'
        }
      end

      eliminar_despiece_existente = !!params[:eliminar_despiece_existente]

      # Se toma y se limpia de inmediato: salvaguarda barata contra
      # doble-click / doble confirmación reexportando el mismo proyecto.
      payload = @rossi_project_payload_pendiente.merge(
        confirmar: true,
        eliminar_despiece_existente: eliminar_despiece_existente
      )
      @rossi_project_payload_pendiente = nil

      enviar_post_rossi_project(payload)

      {
        ok: true,
        processing: true
      }
    end

    def solicitar_numero_proyecto
      prompts = [
        'Número de Proyecto'
      ]

      defaults = [
        ''
      ]

      result = UI.inputbox(
        prompts,
        defaults,
        'Exportar Proyecto a Rossi'
      )

      # El usuario presionó Cancelar
      return nil unless result

      id_proyecto = result[0].to_s.strip

      unless id_proyecto =~ /\A\d+\z/
        UI.messagebox('Debe ingresar un ID de Proyecto numérico válido.')
        return nil
      end

      id_proyecto
    end

    def listar_muebles_proyecto_rossi_async(id_proyecto)
      endpoint_base = PLUGIN.read_default(Plugin::SETTINGS_KEY_ROSSI_API_ENDPOINT, nil)
      api_key = PLUGIN.read_default(Plugin::SETTINGS_KEY_ROSSI_API_KEY, nil)

      if endpoint_base.to_s.strip.empty? || api_key.to_s.strip.empty?
        PLUGIN.trigger_event('on_rossi_project_muebles_result', {
          status: 'error',
          mensaje:
            "No se configuró la conexión con el sistema de gestión Rossi.\n\n" \
            "Configurar una vez desde la Consola de Ruby de SketchUp (Ventana > Consola de Ruby):\n\n" \
            "Ladb::OpenCutList::PLUGIN.write_default('#{Plugin::SETTINGS_KEY_ROSSI_API_ENDPOINT}', 'https://.../api/opencutlist/importar')\n" \
            "Ladb::OpenCutList::PLUGIN.write_default('#{Plugin::SETTINGS_KEY_ROSSI_API_KEY}', 'tu-api-key')"
        })

        return
      end

      Sketchup.status_text = 'ROSSI: consultando amoblamientos del proyecto...'

      UI.start_timer(0.1, false) do
        begin
          uri = URI.parse(endpoint_base)
          uri.path = "/api/opencutlist/proyecto/#{id_proyecto}/muebles"

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == 'https'
          http.open_timeout = 10
          http.read_timeout = 30

          request = Net::HTTP::Get.new(uri.request_uri)
          request['Accept'] = 'application/json'
          request['X-API-KEY'] = api_key

          response = http.request(request)
          codigo = response.code.to_i

          respuesta = begin
            JSON.parse(response.body)
          rescue StandardError
            nil
          end

          if codigo.between?(200, 299) && respuesta && respuesta['ok']
            Sketchup.status_text = 'ROSSI: amoblamientos recibidos'

            PLUGIN.trigger_event('on_rossi_project_muebles_result', {
              status: 'success',
              id_proyecto: id_proyecto,
              muebles: respuesta['muebles'] || []
            })
          else
            Sketchup.status_text = 'ROSSI: el servidor rechazó la consulta'

            PLUGIN.trigger_event('on_rossi_project_muebles_result', {
              status: 'error',
              mensaje:
                (respuesta && respuesta['mensaje']) ||
                "Código HTTP: #{response.code}\n\n#{response.body}"
            })
          end

        rescue StandardError => e
          Sketchup.status_text = 'ROSSI: error de sincronización'

          PLUGIN.trigger_event('on_rossi_project_muebles_result', {
            status: 'error',
            mensaje: "#{e.class}: #{e.message}"
          })
        ensure
          UI.start_timer(3, false) do
            Sketchup.status_text = ''
          end
        end
      end

      nil
    end

    def build_rossi_project_materiales(cutlist_hash)
      groups = cutlist_hash[:groups] || cutlist_hash['groups'] || []

      materiales = []

      groups.each do |group_hash|
        material_type = (
          group_hash[:material_type_strippedname] ||
          group_hash['material_type_strippedname'] ||
          ''
        ).to_s.strip

        next unless material_type == 'sheet_good'

        group_id =
          group_hash[:id] ||
          group_hash['id']

        material_name = (
          group_hash[:material_name] ||
          group_hash['material_name'] ||
          ''
        ).to_s.strip

        espesor = parse_ocl_number(
          group_hash[:std_thickness] ||
          group_hash['std_thickness']
        )

        materiales << {
          nombre_ocl: material_name,
          espesor_ocl: espesor.round(2),
          piezas: build_rossi_project_piezas(group_id)
        }
      end

      materiales
    end

    def build_rossi_project_piezas(group_id)
      return [] if group_id.nil?

      group = @cutlist.get_group(group_id)
      return [] if group.nil?

      # Cada "part" ya representa un tipo de pieza distinto (con su propio
      # "count"), no una pieza física individual.
      group.get_parts(nil, real: true).map do |part|
        {
          n_pieza: part.number.to_s,
          descripcion: part.name.to_s,
          cantidad: part.count.to_i,
          largo: part.length.to_s.to_l.to_mm.round(2),
          ancho: part.width.to_s.to_l.to_mm.round(2),
          grosor: part.thickness.to_s.to_l.to_mm.round(2),

          # ymin/ymax = cantos de longitud; xmin/xmax = cantos de ancho
          # (confirmado en el diálogo "editar pieza" de OCL: secciones
          # "over_length" / "over_width"). Nombre del material de canto,
          # o nil si esa cara no tiene canto asignado.
          canto_ymin: part.edge_material_names[:ymin],
          canto_ymax: part.edge_material_names[:ymax],
          canto_xmin: part.edge_material_names[:xmin],
          canto_xmax: part.edge_material_names[:xmax]
        }
      end
    end

    def enviar_post_rossi_project(payload)
      endpoint_base = PLUGIN.read_default(Plugin::SETTINGS_KEY_ROSSI_API_ENDPOINT, nil)
      api_key = PLUGIN.read_default(Plugin::SETTINGS_KEY_ROSSI_API_KEY, nil)

      if endpoint_base.to_s.strip.empty? || api_key.to_s.strip.empty?
        @rossi_project_payload_pendiente = nil

        PLUGIN.trigger_event('on_rossi_export_project_result', {
          status: 'error',
          mensaje:
            "No se configuró la conexión con el sistema de gestión Rossi.\n\n" \
            "Configurar una vez desde la Consola de Ruby de SketchUp (Ventana > Consola de Ruby):\n\n" \
            "Ladb::OpenCutList::PLUGIN.write_default('#{Plugin::SETTINGS_KEY_ROSSI_API_ENDPOINT}', 'https://.../api/opencutlist/importar')\n" \
            "Ladb::OpenCutList::PLUGIN.write_default('#{Plugin::SETTINGS_KEY_ROSSI_API_KEY}', 'tu-api-key')"
        })

        return
      end

      Sketchup.status_text = 'ROSSI: sincronizando proyecto...'

      UI.start_timer(0.1, false) do
        begin
          # Mismo endpoint/API key que "Exportar a Presupuesto", solo
          # cambia el path: pega al mismo backend gestionrf.
          uri = URI.parse(endpoint_base)
          uri.path = '/api/opencutlist/proyecto'

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == 'https'
          http.open_timeout = 10
          http.read_timeout = 30

          request = Net::HTTP::Post.new(uri.request_uri)
          request['Content-Type'] = 'application/json'
          request['Accept'] = 'application/json'
          request['X-API-KEY'] = api_key
          request.body = JSON.generate(payload)

          response = http.request(request)
          codigo = response.code.to_i

          respuesta = begin
            JSON.parse(response.body)
          rescue StandardError
            nil
          end

          if respuesta && respuesta['requiere_confirmacion']
            # No se limpia @rossi_project_payload_pendiente: es el mismo
            # payload que se reenvía si el usuario confirma.
            Sketchup.status_text = 'ROSSI: requiere confirmación'

            PLUGIN.trigger_event('on_rossi_export_project_result', {
              status: 'requiere_confirmacion',
              mensaje: respuesta['mensaje'],
              materiales_reconocidos: respuesta['materiales_reconocidos'] || [],
              materiales_no_reconocidos: respuesta['materiales_no_reconocidos'] || [],
              piezas_existentes: respuesta['piezas_existentes'] || 0
            })
          elsif codigo.between?(200, 299) && respuesta && respuesta['ok']
            @rossi_project_payload_pendiente = nil

            Sketchup.status_text = 'ROSSI: sincronización completada'

            PLUGIN.trigger_event('on_rossi_export_project_result', {
              status: 'success',
              mensaje: respuesta['mensaje'],
              piezas_creadas: respuesta['piezas_creadas'],
              piezas_reemplazadas: respuesta['piezas_reemplazadas'],
              materiales_no_reconocidos: respuesta['materiales_no_reconocidos'] || []
            })
          else
            @rossi_project_payload_pendiente = nil

            Sketchup.status_text = 'ROSSI: el servidor rechazó el envío'

            PLUGIN.trigger_event('on_rossi_export_project_result', {
              status: 'error',
              mensaje:
                (respuesta && respuesta['mensaje']) ||
                "Código HTTP: #{response.code}\n\n#{response.body}"
            })
          end

        rescue StandardError => e
          @rossi_project_payload_pendiente = nil

          Sketchup.status_text = 'ROSSI: error de sincronización'

          PLUGIN.trigger_event('on_rossi_export_project_result', {
            status: 'error',
            mensaje: "#{e.class}: #{e.message}"
          })
        ensure
          UI.start_timer(3, false) do
            Sketchup.status_text = ''
          end
        end
      end

      nil
    end

    def calcular_cortes_placas_async(
      cutlist_hash,
      datos_presupuesto
    )
      require_relative '../worker/cutlist/cutlist_cuttingdiagram2d_worker'

      groups = cutlist_hash[:groups] || cutlist_hash['groups'] || []

      grupos_placa = groups.select do |group_hash|
        material_type = (
          group_hash[:material_type_strippedname] ||
          group_hash['material_type_strippedname'] ||
          ''
        ).to_s.strip

        material_type == 'sheet_good'
      end

      cortes_por_grupo = {}

      procesar_siguiente_grupo_rossi(
        grupos_placa,
        0,
        cutlist_hash,
        datos_presupuesto,
        cortes_por_grupo
      )
    end

    def procesar_siguiente_grupo_rossi(
      grupos,
      indice,
      cutlist_hash,
      datos_presupuesto,
      cortes_por_grupo
    )
      if indice >= grupos.length
        finalizar_exportacion_rossi(
          cutlist_hash,
          datos_presupuesto,
          cortes_por_grupo
        )

        return
      end

      group_hash = grupos[indice]

      group_id =
        group_hash[:id] ||
        group_hash['id']

      material_name = (
        group_hash[:material_name] ||
        group_hash['material_name'] ||
        'Material sin nombre'
      ).to_s

      # Tamaño estándar de placa utilizado por Rossi.
      std_sheet = '2600mm x 1830mm'

      if group_id.nil?
        puts "ROSSI: grupo sin ID para #{material_name}"

        procesar_siguiente_grupo_rossi(
          grupos,
          indice + 1,
          cutlist_hash,
          datos_presupuesto,
          cortes_por_grupo
        )

        return
      end

      puts "ROSSI: optimizando #{material_name}"
      puts "ROSSI: group_id = #{group_id.inspect}"
      puts "ROSSI: std_sheet = #{std_sheet.inspect}"

      begin
        worker = CutlistCuttingdiagram2dWorker.new(
          @cutlist,
          group_id: group_id,
          std_sheet: std_sheet,
          scrap_sheet_sizes: '',
          saw_kerf: '3mm',
          trimming: '10mm',
          sheet_folding: false
        )

        avanzar_optimizacion_rossi(
          worker,
          grupos,
          indice,
          cutlist_hash,
          datos_presupuesto,
          cortes_por_grupo,
          group_id,
          material_name
        )
      rescue StandardError => e
        puts "ROSSI: error creando el optimizador para #{material_name}"
        puts "#{e.class}: #{e.message}"
        puts e.backtrace.first(10).join("\n")

        UI.messagebox(
          "Error al crear la optimización para " \
          "'#{material_name}'.\n\n" \
          "#{e.class}: #{e.message}"
        )

        cortes_por_grupo[group_id.to_s] = {
          cantidad_cortes: 0,
          cantidad_placas: 0
        }

        procesar_siguiente_grupo_rossi(
          grupos,
          indice + 1,
          cutlist_hash,
          datos_presupuesto,
          cortes_por_grupo
        )
      end
    end

    def avanzar_optimizacion_rossi(
      worker,
      grupos,
      indice,
      cutlist_hash,
      datos_presupuesto,
      cortes_por_grupo,
      group_id,
      material_name
    )
      UI.start_timer(0.05, false) do
        begin
          resultado = worker.run(true)

          puts "ROSSI: resultado worker = #{resultado.class}"
          puts "ROSSI: resultado = #{resultado.inspect}"

          # La primera llamada puede devolver:
          # { estimated_steps: 1 }
          #
          # Todavía no es el diagrama final.
          if resultado.is_a?(Hash)
            puts 'ROSSI: optimizador inicializado, avanzando...'

            avanzar_optimizacion_rossi(
              worker,
              grupos,
              indice,
              cutlist_hash,
              datos_presupuesto,
              cortes_por_grupo,
              group_id,
              material_name
            )

            next
          end

          unless resultado.respond_to?(:sheets)
            raise(
              "El optimizador devolvió un resultado inesperado: " \
              "#{resultado.class}"
            )
          end

          # Si el optimizador terminó con un error (ej. la placa es más
          # chica que las piezas, o no hay forma de ubicarlas), devuelve
          # un resultado con "sheets" vacío PERO "errors" cargado. Sin este
          # chequeo, ese estado es indistinguible de "todavía en proceso"
          # (que también tiene "sheets" vacío) y el loop de abajo nunca
          # termina: sigue reintentando sobre un engine que ya está en
          # estado de error para siempre.
          if resultado.respond_to?(:errors) && resultado.errors && resultado.errors.length > 0
            puts "ROSSI: el optimizador terminó con error para #{material_name}"
            puts "ROSSI: errores = #{resultado.errors.inspect}"

            UI.messagebox(
              "No se pudo calcular el corte para " \
              "'#{material_name}'.\n\n" \
              "#{resultado.errors.inspect}"
            )

            cortes_por_grupo[group_id.to_s] = {
              cantidad_cortes: 0,
              cantidad_placas: 0
            }

            procesar_siguiente_grupo_rossi(
              grupos,
              indice + 1,
              cutlist_hash,
              datos_presupuesto,
              cortes_por_grupo
            )

            next
          end

          # Si ya existen hojas, la optimización terminó.
          if resultado.sheets.length > 0
            puts "ROSSI: optimización terminada para #{material_name}"
            puts "ROSSI: hojas generadas = #{resultado.sheets.length}"

            procesar_resultado_cortes_rossi(
              resultado,
              cortes_por_grupo,
              group_id
            )

            procesar_siguiente_grupo_rossi(
              grupos,
              indice + 1,
              cutlist_hash,
              datos_presupuesto,
              cortes_por_grupo
            )
          else
            puts 'ROSSI: optimización todavía en proceso...'

            avanzar_optimizacion_rossi(
              worker,
              grupos,
              indice,
              cutlist_hash,
              datos_presupuesto,
              cortes_por_grupo,
              group_id,
              material_name
            )
          end

        rescue StandardError => e
          puts "ROSSI: error optimizando #{material_name}"
          puts "#{e.class}: #{e.message}"
          puts e.backtrace.first(10).join("\n")

          cortes_por_grupo[group_id.to_s] = {
            cantidad_cortes: 0,
            cantidad_placas: 0
          }

          procesar_siguiente_grupo_rossi(
            grupos,
            indice + 1,
            cutlist_hash,
            datos_presupuesto,
            cortes_por_grupo
          )
        end
      end
    end

    def procesar_resultado_cortes_rossi(
      cuttingdiagram,
      cortes_por_grupo,
      group_id
    )
      cuttingdiagram_hash = cuttingdiagram.to_hash

      puts 'ROSSI: diagrama final'
      puts JSON.pretty_generate(cuttingdiagram_hash)

      summary =
        cuttingdiagram_hash[:summary] ||
        cuttingdiagram_hash['summary'] ||
        {}

      total_cut_count = (
        summary[:total_cut_count] ||
        summary['total_cut_count'] ||
        0
      ).to_i

      total_used_count = (
        summary[:total_used_count] ||
        summary['total_used_count'] ||
        0
      ).to_i

      cortes_por_grupo[group_id.to_s] = {
        cantidad_cortes: total_cut_count,
        cantidad_placas: total_used_count
      }

      puts "ROSSI: cortes encontrados = #{total_cut_count}"
      puts "ROSSI: placas utilizadas = #{total_used_count}"
    end

    def finalizar_exportacion_rossi(
      cutlist_hash,
      datos_presupuesto,
      cortes_por_grupo
    )
      rossi_payload = {
        schema_version: '1.0',
        source: 'opencutlist',
        numero_presupuesto:
          datos_presupuesto[:numero_presupuesto],
        nombre_amoblamiento:
          datos_presupuesto[:nombre_amoblamiento],
        descripcion:
          datos_presupuesto[:descripcion],
        filename:
          cutlist_hash[:filename] ||
          cutlist_hash['filename'],
        productos: build_rossi_products(
          cutlist_hash,
          cortes_por_grupo
        )
      }

      puts 'ROSSI: payload final'
      puts JSON.pretty_generate(rossi_payload)

      @rossi_payload_pendiente = rossi_payload

      enviar_post_rossi(rossi_payload)
    end

    def calcular_cortes_placas(cutlist_hash)
      require_relative '../worker/cutlist/cutlist_cuttingdiagram2d_worker'

      groups = cutlist_hash[:groups] || cutlist_hash['groups'] || []
      cortes_por_grupo = {}

      groups.each do |group_hash|
        material_type = (
          group_hash[:material_type_strippedname] ||
          group_hash['material_type_strippedname'] ||
          ''
        ).to_s.strip

        next unless material_type == 'sheet_good'

        group_id =
          group_hash[:id] ||
          group_hash['id']

        next if group_id.nil?


        

        # Tamaño de placa Rossi: 2,60 m × 1,83 m
        std_sheet = '2600mm x 1830mm'

        material_name =
          group_hash[:material_name] ||
          group_hash['material_name'] ||
          'Material sin nombre'

        

        begin
          puts "ROSSI: creando optimizador para #{material_name}"
          puts "ROSSI: group_id = #{group_id.inspect}"
          puts "ROSSI: std_sheet = #{std_sheet.inspect}"

          worker = CutlistCuttingdiagram2dWorker.new(
            @cutlist,
            group_id: group_id,
            std_sheet: std_sheet,
            scrap_sheet_sizes: '',
            saw_kerf: '3mm',
            trimming: '10mm',
            sheet_folding: false
          )

          puts 'ROSSI: ejecutando worker.run(false)'

          cuttingdiagram = worker.run(false)

          puts 'ROSSI: optimización terminada'

          cuttingdiagram_hash = cuttingdiagram.to_hash

          puts JSON.pretty_generate(cuttingdiagram_hash)

          summary =
            cuttingdiagram_hash[:summary] ||
            cuttingdiagram_hash['summary'] ||
            {}

          total_cut_count = (
            summary[:total_cut_count] ||
            summary['total_cut_count'] ||
            0
          ).to_i

          total_used_count = (
            summary[:total_used_count] ||
            summary['total_used_count'] ||
            0
          ).to_i

          cortes_por_grupo[group_id.to_s] = {
            cantidad_cortes: total_cut_count,
            cantidad_placas: total_used_count
          }

        rescue StandardError => e
          mensaje = [
            'Error al calcular cortes de placa.',
            '',
            "Material: #{material_name}",
            "Grupo: #{group_id.inspect}",
            "Placa: #{std_sheet.inspect}",
            '',
            "#{e.class}: #{e.message}",
            '',
            e.backtrace.first(10).join("\n")
          ].join("\n")

          puts mensaje
          UI.messagebox(mensaje)

          # Para que la exportación continúe aunque falle el optimizador
          cortes_por_grupo[group_id.to_s] = {
            cantidad_cortes: 0,
            cantidad_placas: 0
          }
        end
      end

      cortes_por_grupo
    end

    def generate_command(settings)
      require_relative '../worker/cutlist/cutlist_generate_worker'

      @cutlist.invalidate if @cutlist

      worker = CutlistGenerateWorker.new(**settings)

      @cutlist = worker.run

      @cutlist.to_hash
    end

    def solicitar_datos_presupuesto
      prompts = [
        'Número de presupuesto',
        'Nombre del amoblamiento',
        'Descripción'
      ]

      defaults = [
        '',
        Sketchup.active_model.title.to_s,
        ''
      ]

      result = UI.inputbox(
        prompts,
        defaults,
        'Datos del presupuesto Rossi'
      )

      # El usuario presionó Cancelar
      return nil unless result

      numero_presupuesto = result[0].to_s.strip
      nombre_amoblamiento = result[1].to_s.strip
      descripcion = result[2].to_s.strip

      if numero_presupuesto.empty?
        UI.messagebox('Debe ingresar el número de presupuesto.')
        return nil
      end

      if nombre_amoblamiento.empty?
        UI.messagebox('Debe ingresar el nombre del amoblamiento.')
        return nil
      end

      {
        numero_presupuesto: numero_presupuesto,
        nombre_amoblamiento: nombre_amoblamiento,
        descripcion: descripcion
      }
    end


    def build_rossi_products(cutlist_hash, cortes_por_grupo = {})
      groups = cutlist_hash[:groups] || cutlist_hash['groups'] || []

      groups.map do |group|
        group_id =
          group[:id] ||
          group['id']

        material_name =
          group[:material_name] ||
          group['material_name'] ||
          ''

        material_type = (
          group[:material_type_strippedname] ||
          group['material_type_strippedname'] ||
          ''
        ).to_s.strip

        producto = {
          nombre_ocl: material_name.to_s.strip,
          tipo: material_type
        }

        case material_type
        when 'sheet_good'
          espesor = parse_ocl_number(
            group[:std_thickness] ||
            group['std_thickness']
          )

          if espesor <= 0
            raise(
              "No se pudo obtener el espesor del material " \
              "'#{material_name}'."
            )
          end

          producto[:cantidad] = parse_ocl_number(
            group[:total_cutting_area] ||
            group['total_cutting_area']
          )

          producto[:unidad] = 'm2'
          producto[:espesor_ocl] = espesor.round(2)

          producto[:cantidad_piezas] = (
            group[:part_count] ||
            group['part_count'] ||
            0
          ).to_i

          optimizacion =
            cortes_por_grupo[group_id.to_s] ||
            {}

          producto[:cantidad_cortes] = (
            optimizacion[:cantidad_cortes] ||
            0
          ).to_i

          producto[:cantidad_placas] = (
            optimizacion[:cantidad_placas] ||
            0
          ).to_i

        when 'edge'
          producto[:cantidad] = parse_ocl_number(
            group[:total_cutting_length] ||
            group['total_cutting_length']
          )

          producto[:unidad] = 'm'

        else
          producto[:cantidad] = (
            group[:part_count] ||
            group['part_count'] ||
            0
          ).to_i

          producto[:unidad] = 'unidad'
        end

        producto
      end
    end

    def enviar_post_rossi(payload)
      endpoint = PLUGIN.read_default(Plugin::SETTINGS_KEY_ROSSI_API_ENDPOINT, nil)
      api_key = PLUGIN.read_default(Plugin::SETTINGS_KEY_ROSSI_API_KEY, nil)

      if endpoint.to_s.strip.empty? || api_key.to_s.strip.empty?
        @rossi_payload_pendiente = nil

        PLUGIN.trigger_event('on_rossi_export_result', {
          status: 'error',
          mensaje:
            "No se configuró la conexión con el sistema de gestión Rossi.\n\n" \
            "Configurar una vez desde la Consola de Ruby de SketchUp (Ventana > Consola de Ruby):\n\n" \
            "Ladb::OpenCutList::PLUGIN.write_default('#{Plugin::SETTINGS_KEY_ROSSI_API_ENDPOINT}', 'https://.../api/opencutlist/importar')\n" \
            "Ladb::OpenCutList::PLUGIN.write_default('#{Plugin::SETTINGS_KEY_ROSSI_API_KEY}', 'tu-api-key')"
        })

        return
      end

      Sketchup.status_text = 'ROSSI: sincronizando presupuesto...'

      UI.start_timer(0.1, false) do
        begin
          uri = URI.parse(endpoint)

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == 'https'
          http.open_timeout = 10
          http.read_timeout = 30

          request = Net::HTTP::Post.new(uri.request_uri)
          request['Content-Type'] = 'application/json'
          request['Accept'] = 'application/json'
          request['X-API-KEY'] = api_key
          request.body = JSON.generate(payload)

          response = http.request(request)
          codigo = response.code.to_i

          respuesta = begin
            JSON.parse(response.body)
          rescue StandardError
            nil
          end

          if respuesta && respuesta['requiere_confirmacion']
            # La vista previa siempre responde 200 (matcheen o no todos
            # los productos). No se limpia @rossi_payload_pendiente: es
            # el mismo payload que se reenvía si el usuario confirma.
            Sketchup.status_text = 'ROSSI: requiere confirmación'

            PLUGIN.trigger_event('on_rossi_export_result', {
              status: 'requiere_confirmacion',
              mensaje: respuesta['mensaje'],
              productos_reconocidos: respuesta['productos_reconocidos'] || [],
              productos_no_reconocidos: respuesta['productos_no_reconocidos'] || []
            })
          elsif codigo.between?(200, 299) && respuesta && respuesta['ok']
            @rossi_payload_pendiente = nil

            Sketchup.status_text = 'ROSSI: sincronización completada'

            PLUGIN.trigger_event('on_rossi_export_result', {
              status: 'success',
              mensaje: respuesta['mensaje'],
              cantidad_productos: respuesta['cantidad_productos'],
              importacion_parcial: respuesta['importacion_parcial'],
              productos_no_reconocidos: respuesta['productos_no_reconocidos'] || []
            })
          else
            @rossi_payload_pendiente = nil

            Sketchup.status_text = 'ROSSI: el servidor rechazó el envío'

            PLUGIN.trigger_event('on_rossi_export_result', {
              status: 'error',
              mensaje:
                (respuesta && respuesta['mensaje']) ||
                "Código HTTP: #{response.code}\n\n#{response.body}"
            })
          end

        rescue StandardError => e
          @rossi_payload_pendiente = nil

          Sketchup.status_text = 'ROSSI: error de sincronización'

          PLUGIN.trigger_event('on_rossi_export_result', {
            status: 'error',
            mensaje: "#{e.class}: #{e.message}"
          })
        ensure
          UI.start_timer(3, false) do
            Sketchup.status_text = ''
          end
        end
      end

      nil
    end

    

    def parse_ocl_number(value)
      return 0.0 if value.nil?

      number = value.to_s.gsub(/[^\d,.\-]/, '')

      # OCL en español devuelve, por ejemplo: "1,58 m²"
      if number.include?(',') && number.include?('.')
        # Formato posible: 1.234,56
        number = number.delete('.').tr(',', '.')
      elsif number.include?(',')
        number = number.tr(',', '.')
      end

      number.to_f
    end

    def add_to_rossi_series_command
      unless @cutlist
        UI.messagebox('Primero debe generar el listado de partes.')

        return {
          ok: false,
          error: 'cutlist_not_generated'
        }
      end

      datos_mueble_serie = solicitar_datos_mueble_serie

      return {
        ok: false,
        cancelled: true
      } unless datos_mueble_serie

      cutlist_hash = @cutlist.to_hash

      rossi_series_payload = build_rossi_series_payload(cutlist_hash, datos_mueble_serie)

      puts 'ROSSI SERIES: payload final'
      puts JSON.pretty_generate(rossi_series_payload)

      enviar_post_rossi_series(rossi_series_payload)

      {
        ok: true,
        processing: true
      }
    end

    def solicitar_datos_mueble_serie
      prompts = [
        'Código del mueble',
        'Nombre',
        'Descripción',
        'Nombre de la variante'
      ]

      defaults = [
        '',
        Sketchup.active_model.title.to_s,
        '',
        ''
      ]

      result = UI.inputbox(
        prompts,
        defaults,
        'Datos del mueble - Rossi Series'
      )

      # El usuario presionó Cancelar
      return nil unless result

      codigo = result[0].to_s.strip
      nombre = result[1].to_s.strip
      descripcion = result[2].to_s.strip
      nombre_variante = result[3].to_s.strip

      if codigo.empty?
        UI.messagebox('Debe ingresar el código del mueble.')
        return nil
      end

      unless codigo =~ /\A\d+\z/
        UI.messagebox('El código del mueble debe ser un número entero (sin letras ni guiones).')
        return nil
      end

      if nombre.empty?
        UI.messagebox('Debe ingresar el nombre del mueble.')
        return nil
      end

      if nombre_variante.empty?
        UI.messagebox('Debe ingresar el nombre de la variante.')
        return nil
      end

      {
        codigo: codigo,
        nombre: nombre,
        descripcion: descripcion,
        nombre_variante: nombre_variante
      }
    end

    def build_rossi_series_payload(cutlist_hash, datos_mueble_serie)
      {
        schema_version: '1.0',
        source: 'opencutlist',
        codigo_mueble: datos_mueble_serie[:codigo],
        nombre_mueble: datos_mueble_serie[:nombre],
        descripcion_mueble: datos_mueble_serie[:descripcion],
        nombre_variante: datos_mueble_serie[:nombre_variante],
        filename: cutlist_hash[:filename] || cutlist_hash['filename'],
        productos: build_rossi_series_products(cutlist_hash)
      }
    end

    def build_rossi_series_products(cutlist_hash)
      groups = cutlist_hash[:groups] || cutlist_hash['groups'] || []

      groups.map do |group_hash|
        group_id = group_hash[:id] || group_hash['id']

        material_name = (
          group_hash[:material_name] ||
          group_hash['material_name'] ||
          ''
        ).to_s.strip

        material_type = (
          group_hash[:material_type_strippedname] ||
          group_hash['material_type_strippedname'] ||
          ''
        ).to_s.strip

        producto = {
          nombre_ocl: material_name,
          tipo: material_type
        }

        case material_type
        when 'sheet_good'
          espesor = parse_ocl_number(
            group_hash[:std_thickness] ||
            group_hash['std_thickness']
          )

          if espesor <= 0
            raise(
              "No se pudo obtener el espesor del material " \
              "'#{material_name}'."
            )
          end

          producto[:cantidad] = parse_ocl_number(
            group_hash[:total_cutting_area] ||
            group_hash['total_cutting_area']
          )

          producto[:unidad] = 'm2'
          producto[:espesor_ocl] = espesor.round(2)

          producto[:cantidad_piezas] = (
            group_hash[:part_count] ||
            group_hash['part_count'] ||
            0
          ).to_i

          producto[:piezas] = build_rossi_series_piezas(group_id)

        when 'edge'
          producto[:cantidad] = parse_ocl_number(
            group_hash[:total_cutting_length] ||
            group_hash['total_cutting_length']
          )

          producto[:unidad] = 'm'

        else
          producto[:cantidad] = (
            group_hash[:part_count] ||
            group_hash['part_count'] ||
            0
          ).to_i

          producto[:unidad] = 'unidad'
        end

        producto
      end
    end

    def build_rossi_series_piezas(group_id)
      return [] if group_id.nil?

      group = @cutlist.get_group(group_id)
      return [] if group.nil?

      group.get_parts(nil, real: true).map do |part|
        {
          nombre: part.name.to_s,
          largo: part.cutting_length.to_s.to_l.to_mm.round(2),
          ancho: part.cutting_width.to_s.to_l.to_mm.round(2),
          cantidad: part.count.to_i,
          canto_largo: part.edge_cutting_length.to_s,
          canto_ancho: part.edge_cutting_width.to_s
        }
      end
    end

    def enviar_post_rossi_series(payload)
      endpoint = PLUGIN.read_default(Plugin::SETTINGS_KEY_ROSSI_SERIES_API_ENDPOINT, nil)
      api_key = PLUGIN.read_default(Plugin::SETTINGS_KEY_ROSSI_API_KEY, nil)

      if endpoint.to_s.strip.empty? || api_key.to_s.strip.empty?
        UI.messagebox(
          "No se configuró la conexión con Rossi Series.\n\n" \
          "Configurar una vez desde la Consola de Ruby de SketchUp (Ventana > Consola de Ruby):\n\n" \
          "Ladb::OpenCutList::PLUGIN.write_default('#{Plugin::SETTINGS_KEY_ROSSI_SERIES_API_ENDPOINT}', 'https://.../api/opencutlist/series')\n" \
          "Ladb::OpenCutList::PLUGIN.write_default('#{Plugin::SETTINGS_KEY_ROSSI_API_KEY}', 'tu-api-key')"
        )
        return
      end

      Sketchup.status_text = 'ROSSI SERIES: sincronizando mueble de catálogo...'

      UI.start_timer(0.1, false) do
        begin
          uri = URI.parse(endpoint)

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == 'https'
          http.open_timeout = 10
          http.read_timeout = 30

          request = Net::HTTP::Post.new(uri.request_uri)
          request['Content-Type'] = 'application/json'
          request['Accept'] = 'application/json'
          request['X-API-KEY'] = api_key
          request.body = JSON.generate(payload)

          response = http.request(request)
          codigo = response.code.to_i

          if codigo.between?(200, 299)
            respuesta = JSON.parse(response.body)

            Sketchup.status_text = 'ROSSI SERIES: sincronización completada'

            UI.messagebox(
              "Mueble agregado a Rossi Series correctamente.\n\n" \
              "#{respuesta['mensaje']}\n" \
              "Código: #{respuesta['codigo_mueble']}\n" \
              "ID mueble serie: #{respuesta['id_mueble_serie']}\n" \
              "Variante: #{respuesta['nombre_variante']} (id #{respuesta['id_variante']})\n" \
              "Productos: #{respuesta['cantidad_productos']}"
            )
          else
            Sketchup.status_text = 'ROSSI SERIES: el servidor rechazó el envío'

            UI.messagebox(
              "El servidor rechazó el envío.\n\n" \
              "Código HTTP: #{response.code}\n\n" \
              "#{response.body}"
            )
          end

        rescue StandardError => e
          Sketchup.status_text = 'ROSSI SERIES: error de sincronización'

          UI.messagebox(
            "Error al enviar el POST.\n\n" \
            "#{e.class}: #{e.message}"
          )
        ensure
          UI.start_timer(3, false) do
            Sketchup.status_text = ''
          end
        end
      end

      nil
    end

    def export_command(settings)
      require_relative '../worker/cutlist/cutlist_export_worker'

      # Setup worker
      worker = CutlistExportWorker.new(@cutlist, **settings)

      # Run !
      worker.run
    end

    def estimate_start_command(settings)
      require_relative '../worker/cutlist/cutlist_estimate_worker'

      # Setup worker
      @estimate_worker = CutlistEstimateWorker.new(@cutlist, **settings)

      # Run !
      @estimate_worker.run
    end

    def estimate_advance_command
      return { :errors => [ 'default.error' ] } unless @estimate_worker

      # Run !
      @estimate_worker.run(:advance)
    end

    def estimate_next_command
      return { :errors => [ 'default.error' ] } unless @estimate_worker

      # Run !
      @estimate_worker.run(:next)
    end

    def estimate_cancel_command
      return { :errors => [ 'default.error' ] } unless @estimate_worker

      # Run !
      @estimate_worker.run(:cancel)
    end

    def numbers_command(settings, reset)
      require_relative '../worker/cutlist/cutlist_numbers_worker'

      # Setup worker
      worker = CutlistNumbersWorker.new(@cutlist, **(settings.merge({ :reset => reset })))

      # Run !
      worker.run
    end

    def highlight_parts_command(settings)
      require_relative '../worker/cutlist/cutlist_highlight_parts_worker'

      # Setup worker
      worker = CutlistHighlightPartsWorker.new(@cutlist, **settings)

      # Run !
      worker.run
    end

    def layout_parts_command(settings)
      require_relative '../worker/cutlist/cutlist_layout_parts_worker'

      # Setup worker
      worker = CutlistLayoutPartsWorker.new(@cutlist, **settings)

      # Run !
      worker.run
    end

    def layout_to_layout_command(settings)
      require_relative '../worker/cutlist/cutlist_layout_to_layout_worker'

      # Setup worker
      worker = CutlistLayoutToLayoutWorker.new(@cutlist, **settings)

      # Run !
      worker.run
    end

    def part_get_thumbnail_command(part_data)
      require_relative '../worker/cutlist/cutlist_get_thumbnail_worker'

      # Setup worker
      worker = CutlistGetThumbnailWorker.new(@cutlist, **part_data)

      # Run !
      worker.run
    end

    def part_update_command(settings)
      require_relative '../worker/cutlist/cutlist_part_update_worker'

      # Setup worker
      worker = CutlistPartUpdateWorker.new(@cutlist, **settings)

      # Run !
      worker.run
    end

    def write_parts_command(settings)
      require_relative '../worker/cutlist/cutlist_write_parts_worker'

      # Setup worker
      worker = CutlistWritePartsWorker.new(@cutlist, **settings)

      # Run !
      worker.run
    end

    def group_cuttingdiagram1d_start_command(settings)
      require_relative '../worker/cutlist/cutlist_cuttingdiagram1d_worker'

      # Setup worker
      @cuttingdiagram1d_worker = CutlistCuttingdiagram1dWorker.new(@cutlist, **settings)

      # Run !
      cuttingdiagram1d = @cuttingdiagram1d_worker.run(true)

      cuttingdiagram1d.to_hash
    end

    def group_cuttingdiagram1d_advance_command
      return { :errors => [ 'default.error' ] } unless @cuttingdiagram1d_worker

      # Run !
      cuttingdiagram1d = @cuttingdiagram1d_worker.run(true)

      if cuttingdiagram1d.bars.length > 0
        @cuttingdiagram1d_worker = nil
        @cuttingdiagram1d = cuttingdiagram1d
      end

      cuttingdiagram1d.to_hash
    end

    def cuttingdiagram1d_write_command(settings)
      require_relative '../worker/cutlist/cutlist_cuttingdiagram1d_write_worker'

      # Setup worker
      worker = CutlistCuttingdiagram1dWriteWorker.new(@cutlist, @cuttingdiagram1d, **settings)

      # Run !
      worker.run
    end

    def group_cuttingdiagram2d_start_command(settings)
      require_relative '../worker/cutlist/cutlist_cuttingdiagram2d_worker'

      # Setup worker
      @cuttingdiagram2d_worker = CutlistCuttingdiagram2dWorker.new(@cutlist, **settings)

      # Run !
      cuttingdiagram2d = @cuttingdiagram2d_worker.run(true)

      cuttingdiagram2d.to_hash
    end

    def group_cuttingdiagram2d_advance_command
      return { :errors => [ 'default.error' ] } unless @cuttingdiagram2d_worker

      # Run !
      cuttingdiagram2d = @cuttingdiagram2d_worker.run(true)

      if cuttingdiagram2d.sheets.length > 0
        @cuttingdiagram2d_worker = nil
        @cuttingdiagram2d = cuttingdiagram2d
      end

      cuttingdiagram2d.to_hash
    end

    def cuttingdiagram2d_write_command(settings)
      require_relative '../worker/cutlist/cutlist_cuttingdiagram2d_write_worker'

      # Setup worker
      worker = CutlistCuttingdiagram2dWriteWorker.new(@cutlist, @cuttingdiagram2d, **settings)

      # Run !
      worker.run
    end

    def labels_command(settings)
      require_relative '../worker/cutlist/cutlist_labels_worker'

      # Setup worker
      worker = CutlistLabelsWorker.new(@cutlist, **settings)

      # Run !
      worker.run
    end

    def reset_prices_command
      require_relative '../worker/cutlist/cutlist_reset_prices_worker'

      # Setup worker
      worker = CutlistResetPricesWorker.new

      # Run !
      worker.run
    end


    def group_packing_start_command(settings)
      require_relative '../worker/cutlist/cutlist_packing_worker'

      # Setup worker
      @packing_worker = CutlistPackingWorker.new(@cutlist, **settings)

      # Run !
      packing = @packing_worker.run(:start)

      @packing = packing unless packing.running

      packing.to_hash
    end

    def group_packing_advance_command
      return { :errors => [ 'default.error' ] } unless @packing_worker

      # Run !
      packing = @packing_worker.run(:advance)

      @packing = packing unless packing.running

      packing.to_hash
    end

    def group_packing_cancel_command
      return { :errors => [ 'default.error' ] } unless @packing_worker

      # Run !
      packing = @packing_worker.run(:cancel)

      @packing = packing unless packing.running

      packing.to_hash
    end

    def packing_write_command(settings)
      require_relative '../worker/cutlist/cutlist_packing_write_worker'

      # Setup worker
      worker = CutlistPackingWriteWorker.new(@cutlist, @packing, **settings)

      # Run !
      worker.run
    end

  end

end