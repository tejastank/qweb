#!/usr/bin/ruby
# vim:set noet fdm=syntax fdl=0 fdc=3 fdn=2:

require "rexml/document"
require "fileutils"
require "base64"
require "zlib"
require "date"

class QWebContext
	def initialize(context)
		@qweb_context={};
		context.each { |k, v|
			self[k]=v;
		}
	end
	def method_missing(name,*args)
		if m=@qweb_context[name.to_s]
			return m
		elsif t=@qweb_context["template"]
			return t.send(name, *args)
		end
	end

	def []=(k,v)
		@qweb_context[k]=v
		instance_variable_set("@#{k}", v) if k.kind_of?(String)
		return v
	end
	def [](k)
		return @qweb_context[k]
	end
	def clone
		return QWebContext.new(@qweb_context)
	end
	def merge!(src)
		@qweb_context.merge!(src)
	end

	def qweb_eval_object(expr)
		if r=@qweb_context[expr]
			return r
		else
			begin
				r=instance_eval(expr)
			rescue SyntaxError, NameError => boom
				r="String doesn't compile: " +expr+ boom
			rescue StandardError => bang
				r="Error running script: " +expr+ bang
			end
			return r
		end
	end
	def qweb_eval_str(expr)
		if expr=="0":
			return @qweb_context[0]
		else
			return qweb_eval_object(expr).to_s
		end
	end
	def qweb_eval_bool(expr)
		if qweb_eval_object(expr)
			return true
		else
			return false
		end
	end
	def qweb_eval_format(expr)
		begin
			r=eval("<<QWEB_EXPR\n#{expr}\nQWEB_EXPR\n").chop!
		rescue SyntaxError, NameError => boom
			r="String doesn't compile: " +expr+ boom
		rescue StandardError => bang
			r="Error running script: " +expr+ bang
		end
		return r
	end
end

class QWeb
	# t-att t-raw t-esc t-if t-foreach t-set t-call t-trim
	attr_accessor :prefix, :templates
	def initialize(xml=nil)
		@templates={}
		@tag={}
		@att={}
		methods.each { |m|
			@tag[m[11..-1].sub("_", "-")]=method(m) if m =~ /^render_tag_/
			@att[m[11..-1].sub("_", "-")]=method(m) if m =~ /^render_att_/
		}
		add_template(xml) if xml
	end
	def add_template(s)
		if s.respond_to? "root"
			doc=s
		elsif s =~ /\<\?xml/
			doc=REXML::Document.new(s)
		else
			doc=REXML::Document.new(File.new(s))
		end
		@prefix ||= doc.root.attributes["prefix"] || "t"
		@prereg = Regexp.new("^#{@prefix}-")
		@prelen1 = @prefix.length+1
		doc.root.elements.each(@prefix) { |e|
			@templates[e.attributes["#{@prefix}-name"]]=e
		}
	end
	def get_template(name)
		return @templates[name]
	end
	def template_exists?(name)
		return @templates.has_key?(name)
	end
	# Evaluation
	def eval_object(e,v)
		return v.qweb_eval_object(e)
	end
	def eval_format(e,v)
		return v.qweb_eval_format(e)
	end
	def eval_str(e,v)
		return v.qweb_eval_str(e)
	end
	def eval_bool(e,v)
		return v.qweb_eval_bool(e)
	end
	# Escaping
	def escape_text(string)
		string.gsub(/&/n, '&amp;').gsub(/>/n, '&gt;').gsub(/</n, '&lt;')
	end
	def escape_att(string)
		string.gsub(/&/n, '&amp;').gsub(/\"/n, '&quot;').gsub(/>/n, '&gt;').gsub(/</n, '&lt;')
	end
	# Rendering
	def render(tname,v={})
		return render_context(tname,QWebContext.new(v))
	end
	def render_context(tname,v)
		v["__TEMPLATE__"] = tname
		if n=@templates[tname]
			return render_node(n,v)
		else
			return "qweb: template '#{tname}' not found"
		end
	end
	def render_node(e,v)
		r=""
		if e.node_type==:text
			r=e.value
		elsif e.node_type==:element
			g_att = {}
			t_render=nil
			t_att={}
			e.attributes.each do |an,av|
				if an =~ @prereg
					n=an[@prelen1..-1]
					found=false
					# Attributes
					for i,m in @att;
						if n[0...i.size] == i
							#g_att << m.call(e,an,av,v)
							g_att.update m.call(e, an, av, v)
							found=true
							break
						end
					end
					if not found
						if n =~ Regexp.new("^eval-")
							n = n[5..-1]
							av = eval_str(av, v)
						end
						if @tag[n]
							t_render = n
						end
						t_att[n]=av
					end
				else
					g_att[an]=av
				end
			end
			if t_render:
				r = @tag[t_render].call(e, t_att, g_att, v)
			else
				r = render_element(e, t_att, g_att, v)
			end
		end
		return r
	end
	def render_element(e, t_att, g_att, v)
		l_inner=[]
		e.each { |n|
			l_inner << render_node(n,v)
		}
		inner=render_trim(l_inner.join(), t_att)
		if e.name==@prefix
			return inner
		elsif inner.length==0
			return sprintf("<%s%s/>", e.name, render_atts(g_att))
		else
			return sprintf("<%s%s>%s</%s>", e.name, render_atts(g_att), inner, e.name)
		end
	end
	def render_atts(atts)
		r=""
		atts.each do |an,av|
			r << sprintf(' %s="%s"',an,escape_att(av))
		end
		return r
	end
	def render_trim(s, t_att)
		trim = t_att["trim"]
		if !trim
			return s
		elsif trim == 'left'
			return s.lstrip
		elsif trim == 'right'
			return s.rstrip
		elsif trim == 'both'
			return s.strip
		end
	end
	# Attributes
	def render_att_att(e,an,av,v)
		if an =~ Regexp.new("^#{@prefix}-attf-")
			att = an[@prelen1+5..-1]
			val=eval_format(av,v)
		elsif an =~ Regexp.new("^#{@prefix}-att-")
			att = an[@prelen1+4..-1]
			val=eval_str(av,v)
		else
			o=eval_object(av,v)
			#TODO: Will cause error if object is not an array, maybe we should check if respondto? [] but what to do if not ?
			att=o[0]
			#TODO: Maybe we should check if att is a valid string for an attribute ? But what to do if not ?
			val=o[1]
		end
		#return sprintf(' %s="%s"',att,escape_att(val))
		return {att => val}
	end
	# Tags
	def render_tag_raw(e,t_att,g_att,v)
		return render_trim(eval_str(t_att["raw"], v), t_att)
	end
	def render_tag_rawf(e,t_att,g_att,v)
		return render_trim(eval_format(t_att["rawf"], v), t_att)
	end
	def render_tag_esc(e,t_att,g_att,v)
		return escape_text(render_trim(eval_str(t_att["esc"], v), t_att))
	end
	def render_tag_escf(e,t_att,g_att,v)
		return escape_text(render_trim(eval_format(t_att["escf"], v), t_att))
	end
	def render_tag_foreach(e,t_att,g_att,v)
		expr=t_att["foreach"]
		enum=eval_object(expr,v)
		if enum
			var=t_att['as'] || expr.gsub(/[^a-zA-Z0-9]/,'_')
			d=v.clone
			size=-1
			size=enum.length if enum.respond_to? "length"
			d["%s_size"%var]=size
			d["%s_all"%var]=enum
			index=0
			ru=[]
			for i in enum
				d["%s_value"%var]=i
				d["%s_index"%var]=index
				d["%s_first"%var]=index==0
				d["%s_last"%var]=index+1==size
				d["%s_parity"%var]=(index%2==1 ? 'odd' : 'even')
				d.merge!(i) if i.kind_of?(Hash)
				d[var]=i
				ru << render_element(e,t_att,g_att,d)
				index+=1
			end
			return ru.join()
		else
			return "qweb: #{@prefix}-foreach %s not found."%expr
		end
	end
	def render_tag_if(e,t_att,g_att,v)
		if eval_bool(t_att["if"],v)
			return render_element(e, t_att, g_att, v)
		else
			return ""
		end
	end
	def render_tag_call(e,t_att,g_att,v)
		if t_att["import"]
			d = v
		else
			d = v.clone
		end
		d[0] = render_element(e, t_att, g_att, d)
		return render_context(t_att["call"],d)
	end
	def render_tag_set(e,t_att,g_att,v)
		if t_att["eval"]
			v[t_att["set"]]=eval_object(t_att["eval"],v)
		else
			v[t_att["set"]] = render_element(e, t_att, g_att, v)
		end
		return ""
	end
	def render_tag_ruby(e, t_att, g_att, v)
		code =  render_element(e, t_att, g_att, v)
		r=render_trim(v.instance_eval(code).to_s, t_att)
		r="" if t_att["ruby"]=="quiet"
		return r
	end
end

class QWebField
	attr_accessor :type, :name, :value, :values, :multiple, :options, :trim, :check, :missing, :in_xml, :is_data, :clicked,
					:custom_data, :css_valid, :css_invalid, :css_unsubmitted, :form
	def initialize(name)
		@form = nil
		@type = nil
		@name = name
		@trim = true
		@check = nil
		@is_data = false
		@multiple = false
		@options = []
		@custom_data = nil
		@css_invalid = "qweb_invalid"
		@css_valid = "qweb_valid"
		@css_unsubmitted = "qweb_unsubmitted"
		reset
	end
	def reset
		@in_xml = false
		@value = ""
		@values = []
		@valid = false
		@missing = true
		@clicked = false
		@clicked_x = 0
		@clicked_y = 0
	end
	def is_valid?
		return @valid
	end
	def is_empty?
		return @value.length == 0
	end
	def is_missing?
		return @missing
	end
	def is_clicked?
		return @clicked
	end
	def is_in_xml?
		return @in_xml
	end
	def is_data?
		return @is_data
	end

	def add_css(s)
		s ||= ""
		if !@form.is_submitted?
			s += " #{@css_unsubmitted} #{css_unsubmitted}_#{@type.to_s}"
		else
			css = (is_valid?) ? @css_valid : @css_invalid
			s += " #{css} #{css}_#{@type.to_s}"
		end
		return s.strip
	end
	def check_validity
		if is_missing?
			return @valid = false
		end
		check = @check
		case @check
			when nil
				return @valid = true
			when "email"
				check = "/^[^@#!& ]+@[A-Za-z0-9-][.A-Za-z0-9-]{0,64}\.[A-Za-z]{2,5}$/"
			when "date"
				check = "/^(19|20)\d\d-(0[1-9]|1[012])-(0[1-9]|[12][0-9]|3[01])$/"
			when "options"
				if multiple
					v = true
					@values.each { |i|
						v = false if !@options.member?(i)
					}
					return @valid = v
				else
					return @valid = @options.member?(@value)
				end
			when "custom"
				m = "check_tag_input_#{@type}"
				return @valid = $qweb.respond_to?(m) && $qweb.method(m).call(self)
		end
		if check[0].chr == "/" && check[-1].chr == "/"
			return @valid = (@value =~ Regexp.new(check[1..-2])) ? true : false
		else
			#TODO: What to do here ? Call check_xxxxx method ?
			return @valid = false
		end
	end
end
class QWebForm
	attr_accessor :name, :fields, :errors, :submitted, :clicked_button, :request
	def initialize(name = nil)
		@request = nil
		@name = nil
		@fields = {}
		@submitted = false
		@valid = false
		@clicked_button = ""
		@trim_fields = false
		reset
	end
	def reset
		@errors = []
	end
	def [](k)
		k = k.to_s
		unless @fields.key? k
			@fields[k] = QWebField.new(k)
		end
		return @fields[k]
	end
	def serialize
		# TODO: Ask antony if we should serialize dates of xml templates and check it back on_submit in order to manage cases
		# when xml has changed between render and user's post. Maybe QwebRails could set a global value when xml has changed
		@fields.each { |fn, fi|
			unless fi.is_in_xml?
				@fields.delete fn
			end
		}
		@request = nil
		# dump cree un dictionaire avec que les fields et attribut de fiels necessaires
		o={
			:name => @name,
			:fields => @fields,
		}
		ser = Marshal.dump o
		p ser
		puts "*" * 40
		puts "Serialization length = #{ser.length}"
		ser = Zlib::Deflate.new(9).deflate(ser, Zlib::FINISH)
		puts "Compressed length = #{ser.length}"
		ser = Base64::encode64 ser
		puts "Base64 encoded length = #{ser.length}"
		puts "*" * 40
		return ser
	end
	def unserialize(s)
		s = Base64::decode64(s)
		s = Zlib::Inflate.inflate(s)
		o = Marshal.load s
		@name = o[:name]
		@fields = o[:fields]
	end
	def is_submitted?
		return @submitted
	end
	def is_valid?
		return @valid
	end
	def is_submitted_and_valid?
		return is_submitted? && is_valid?
	end
	def is_submitted_but_invalid?
		return is_submitted? && !is_valid?
	end

	def on_submit
		reset
		@submitted = true
		@valid = true
		@fields.each { |fn, fi|
			fi.reset
			if @request.key? fn
				fi.missing = false
				if fi.type == :submit
					fi.clicked = true
					@clicked_button = fn
				else
					if fi.multiple
						v = @request[fn].to_a
						fi.multiple = true
						v.each { |i| i.strip! } if fi.trim || @trim_fields
						fi.value = v.join(",")
						fi.values = v
					else
						v = @request[fn].to_s
						fi.value = (fi.trim || @trim_fields) ? v.strip : v
					end
				end
			else
				fi.value = ""
			end
			if fi.is_data? && !fi.check_validity
				@errors << fn
				@valid = false
			end
		}
	end
	def data
		r = {}
		@fields.each { |fn, fi|
			if fi.is_data?
				r[fn] = fi.value
			end
		}
		return r
	end
end
class QWebHtml < QWeb
	attr_accessor :prefix, :templates
	def initialize(xml = nil)
		@templates = {}
		@tag = {}
		@att = {}

		# TODO: use super.initialize and make this after
		@forms = {}
		@cform = nil

		methods.each { |m|
			@tag[m[11..-1].sub("_", "-")] = method(m) if m =~ /^render_tag_/
			@att[m[11..-1].sub("_", "-")] = method(m) if m =~ /^render_att_/
		}
		add_template(xml) if xml
	end
	def form(request, fname = nil)
		f = QWebForm.new fname
		f.request = request
		@cform = f
		if fname
			ser = request["__FORM__#{fname}__"]
			@forms[fname] = f
		else
			request.each do |k, v|
				if k =~ /^__FORM__/
					ser = v
					break
				end
			end
		end
		if ser
			f.unserialize ser
			f.on_submit
		end
		return f
	end

	# Html tags
	def render_tag_header(e, t_att, g_att, v)
		if @response
			@response.headers[t_att["header"]] = render_element(e, g_att, v)
		end
		return nil
	end

	# Forms handling
	def render_tag_form(e, t_att, g_att, v)
		fn = t_att["form"]
		unless f = @forms[fn] || @cform
			return "qweb: form '#{fn}' was not initialized. Should call QWebHtml.form() before rendering"
		end
		@cform = f
		g_att["name"] ||= fn
		g_att["id"] ||= fn
		r = '<form%s>' % render_atts(g_att)
		r << render_element(e, t_att, g_att, v)
		r << sprintf('<input type="hidden" name="__FORM__%s__" value="%s"/></form>', escape_att(fn), escape_att(f.serialize))
		return r
	end

	def new_field(name, type, t_att, g_att)
		fi = @cform[name]
		fi.form = @cform
		fi.type = type
		fi.check = t_att["check"]
		fi.trim = true if t_att["trim"]
		fi.in_xml = true
		g_att["name"] = name
		unless type == :submit
			fi.is_data = true
			g_att["class"] = fi.add_css(g_att["class"])
		end
		return fi
	end
	def new_custom_field(name, type, t_att, g_att)
		fi = @cform[name]
		fi.form = @cform
		fi.type = type
		fi.check = "custom"
		fi.in_xml = true
		fi.is_data = true
		fi.custom_data = t_att
		return fi
	end

	def render_tag_input_text(e, t_att, g_att, v)
		tn = t_att["input-text"]
		fi = new_field(tn, :text, t_att, g_att)
		g_att["value"] = fi.value
		return sprintf('<input type="text"%s/>', render_atts(g_att))
	end
	def render_tag_input_password(e, t_att, g_att, v)
		tn = t_att["input-password"]
		fi = new_field(tn, :password, t_att, g_att)
		g_att["value"] = fi.value
		return sprintf('<input type="password"%s/>', render_atts(g_att))
	end
	def render_tag_input_textarea(e, t_att, g_att, v)
		tn = t_att["input-textarea"]
		fi = new_field(tn, :textarea, t_att, g_att)
		return sprintf('<textarea%s>%s</textarea>', render_atts(g_att), escape_text(fi.value))
	end

	def render_tag_input_select(e, t_att, g_att, v)
		tn = t_att["input-select"]
		fi = new_field(tn, :select, t_att, g_att)
		fi.options = []
		if t_att["multiple"]
			fi.multiple = true
			g_att["multiple"] = "multiple"
			g_att["name"] = tn + "[]"
		end
		@current_select = tn
		return sprintf('<select%s>%s</select>', render_atts(g_att), render_element(e, t_att, g_att, v))
	end
	def render_tag_input_option(e, t_att, g_att, v)
		fi = @cform[@current_select]
		tv = t_att["input-option"]
		fi.options << tv
		g_att["value"] = tv
		if fi.multiple
			g_att["selected"] = "selected" if fi.values.member?(tv)
		else
			g_att["selected"] = "selected" if tv == fi.value
		end
		return sprintf('<option%s>%s</option>', render_atts(g_att), render_element(e, t_att, g_att, v))
	end

	def render_tag_input_radio(e, t_att, g_att, v)
		tn = t_att["input-radio"]
		fi = new_field(tn, :radio, t_att, g_att)
		tv = t_att["value"]
		fi.options << tv
		g_att["value"] = tv
		g_att["checked"] = "checked" if tv == fi.value
		return sprintf('<input type="radio"%s/>', render_atts(g_att))
	end
	def render_tag_input_checkbox(e, t_att, g_att, v)
		tn = t_att["input-checkbox"]
		fi = new_field(tn, :checkbox, t_att, g_att)
		fi.multiple = true
		tv = t_att["value"]
		fi.options << tv
		g_att["value"] = tv
		g_att["name"] = tn + "[]"
		g_att["checked"] = "checked" if fi.values.member?(tv)
		return sprintf('<input type="checkbox"%s/>', render_atts(g_att))
	end

	def render_tag_input_date(e, t_att, g_att, v)
		tn = t_att["input-date"]
		fi = new_custom_field(tn, :date, t_att, g_att)

		day = sprintf('<select name="%s_day"/><option value=""></option>', tn)
		(1..31).each { |i| day << sprintf('<option value="%s">%s</option>', i, i) }
		day << "</select>\n"

		mnames = (t_att["months"].nil?) ? Date::MONTHNAMES : t_att["months"].split(",").unshift(nil)
		month = sprintf('<select name="%s_month"/><option value=""></option>', tn)
		(1..mnames.length - 1).each { |i| month << sprintf('<option value="%s">%s</option>', i, mnames[i]) }
		month << "</select>\n"

		year = sprintf('<input type="text" name="%s_year" value="" size="4" maxlength="4"/>', tn)
		hidden = sprintf('<input type="hidden" name="%s" value=""/>', tn)
		return hidden + day + month + year
	end
	def check_tag_input_date(fi, mode = nil)
		day = fi.form.request["#{fi.name}_day"].to_i
		month = fi.form.request["#{fi.name}_month"].to_i
		year = fi.form.request["#{fi.name}_year"].to_i
		case mode
			when nil
				return check_tag_input_date(fi, :day) && check_tag_input_date(fi, :month) && check_tag_input_date(fi, :year)
			when :day
				return true if (1..31) === day
			when :month
				return true if (1..12) === day
			when :year
				return false
			else
				return false
		end
		return false
	end
	def get_tag_input_date()
		p "get tag input date"
		return "DATE"
	end

	def render_tag_input_submit(e, t_att, g_att, v)
		tn = t_att["input-submit"]
		fi = new_field(tn, :submit, t_att, g_att)
		fi.is_data = false
		fi.value = g_att["value"]
		return sprintf('<input type="submit"%s/>', render_atts(g_att))
	end

end

class QWebRails
	def self.init()
		# TODO: ASK antony if I can add a 'template' param to init(), param can be string (template name) or
		# array of template names. if nil, default to @@qweb_template. Also add support for xml time management
		# when there are multiple xml files. And last, a global variable $qweb_xml_changed
		ApplicationController.class_eval do
			@@qweb_template=RAILS_ROOT+"/app/controllers/qweb.xml"
			def qweb_load(fname=nil)
				fname ||= @@qweb_template
				if File.mtime(fname).to_i!=$qweb_time
					$qweb=QWebHtml.new(fname)
					$qweb_time=File.mtime(fname).to_i
				end
			end
			def qweb_render(arg=nil)
				t=nil
				t=arg[:template] if arg.kind_of?(Hash)
				t||=default_template_name
				if $qweb.template_exists?(t)
					add_variables_to_assigns
					render_text($qweb.render(t,@assigns))
				else
					if respond_to?(:render_orig)
						return render_orig(arg)
					else
						return render(arg)
					end
				end
			end
			alias :render_orig :render
			alias :render :qweb_render
			before_filter :qweb_load
		end
		# Hack
		QWebContext.class_eval('include ApplicationHelper')
	end
end

if __FILE__ == $0
	v = {"varname"=> "caca","pad" => " Hey ", "number" => 4, "name" => "Fabien <agr@amigrave.com>", "ddd" => 4..8}
	q = QWebHtml.new("demo.xml")
	@request = {}
	f = q.form(v, @request)
	unless f.is_submitted?
		f[:login].value = "agr"
	end
	print q.render("main/index",v)
end
