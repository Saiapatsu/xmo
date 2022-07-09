-- <Object type="0x01ff" id="Sheep">asdf<foo/></Object>
-- <       type="        id="      >    <   /> /Object>
--  Object       0x01ff"     Sheep" asdf foo  <
-- text
-- markup
--  stag
--         attr
--               value
--                       attr
--                           value
--                                 attr
--                                 tagend (opening)
--                                  text
--                                      markup
--                                       stag
--                                          attr
--                                          tagend (self-closing)
--                                            text
--                                            markup
--                                             etag
--                                                     text
--                                                     markup
--                                                     eof

--[[

code todo:
	make parsing more bulletproof/more error-happy
	look over all errors and ensure the positions are right

spec todo:
	https://www.w3.org/TR/xml/
	add a variant of Text that goes up to entities, leaving it up to the user to expand them?
	add XML preamble support, if only to skip it entirely
	parse names correctly per https://www.w3.org/TR/xml/#charsets

]]

local xmls = {}

-- Markup
-- Use at "<" or EOF
-- Transition to STag, ETag, CDATA, Comment, PI or MalformedTag
-- Return nil
function xmls.markup(str, pos)
	if pos > #str then
		return pos, xmls.eof, nil
	end
	
	local sigil = str:sub(pos + 1, pos + 1)
	
	if sigil:match("%w") then -- <tag
		return pos + 1, xmls.stag, nil
		
	elseif sigil == "/" then -- </
		if str:sub(pos + 2, pos + 2):match("%w") then -- </tag
			return pos + 2, xmls.etag, nil
		else -- </>
			return pos + 1, xmls.malformed, nil
		end
		
	elseif sigil == "!" then -- <!
		if str:sub(pos + 2, pos + 3) == "--" then -- <!--
			return pos + 4, xmls.comment, nil
		elseif str:sub(pos + 2, pos + 8) == "[CDATA[" then -- <![CDATA[
			return pos + 9, xmls.cdata, nil
		else -- <!asdf
			return pos + 1, xmls.malformed, nil
		end
		
	elseif sigil == "?" then -- <?
		return pos + 1, xmls.pi, nil
		
	else -- <\
		return pos + 1, xmls.malformed, nil
	end
end

-- Name of starting tag
-- Use at name character after "<"
-- Transition to Attr
-- Return end of name
function xmls.stag(str, pos)
	pos = str:match("^%w+()", pos)
	if pos == nil then
		error("Invalid tag name at " .. pos)
	end
	return str:match("^[ \t\r\n]*()", pos), xmls.attr, pos - 1
end

-- Name of ending tag
-- Use at name character after "</"
-- Transition to Text
-- Return end of name
function xmls.etag(str, pos)
	pos = str:match("^%w+()", pos)
	if pos == nil then
		error("Invalid etag name at " .. pos)
		
	elseif str:sub(pos, pos) ~= ">" then
		-- todo: is a trailing space in an etag valid?
		error("Malformed etag at " .. pos) -- incorrect position
	end
	return pos + 1, xmls.text, pos - 1
end

-- Content of CDATA section
-- Use after "<![CDATA["
-- Transition to Text
-- Return end of content
function xmls.cdata(str, pos)
	-- todo: not a great idea to make this a case of Markup,
	-- because it is actually text data
	local pos2 = str:match("%]%]>()", pos)
	if pos2 then
		return pos2, xmls.text, pos2 - 4
	else
		-- unterminated
		error("Unterminated CDATA section at " .. pos)
		-- pos = #str
		-- return pos, xmls.text, pos
	end
end

-- Content of comment
-- Use after "<!--"
-- Transition to Text
-- Return end of content
function xmls.comment(str, pos)
	local pos2 = str:match("%-%->()", pos)
	if pos2 then
		return pos2, xmls.text, pos2 - 4
	else
		-- unterminated
		error("Unterminated comment at " .. pos)
		-- pos = #str
		-- return pos, xmls.text, pos
	end
end

-- Content of processing instruction
-- Use after "<?"
-- Transition to Text
-- Return end of content
function xmls.pi(str, pos)
	local pos2 = str:match("?>()", pos)
	if pos2 then
		return pos2, xmls.text, pos2 - 3
	else
		-- unterminated
		error("Unterminated processing instruction at " .. pos)
		-- pos = #str
		-- return pos, xmls.text, pos
	end
end

-- Content of an obviously malformed tag
-- Use after "<"
-- Transition to Text
-- Return nil
function xmls.malformed(str, pos)
	-- zip to after >
	error("Malformed tag at " .. pos)
end

-- Attribute name or end of tag (end of attribute list).
-- Use at attribute name or ">" or "/>"
-- Transition to Value and return end of name
-- Transition to TagEnd and return nil
function xmls.attr(str, pos)
	if str:match("^[^/>]", pos) then
		local nameend = str:match("^%w+()", pos)
		if nameend == nil then
			error("Invalid attribute name at " .. pos)
		end
		pos = str:match("^[ \t\r\n]*()", nameend)
		if str:sub(pos, pos) ~= "=" then
			error("Malformed attribute at " .. pos)
		end
		pos = str:match("^[ \t\r\n]*()", pos + 1)
		return pos, xmls.value, nameend - 1
	else
		return pos, xmls.tagend, nil
	end
end

-- Attribute value
-- Use at "'" or '"'
-- Transition to Attr
-- Return end of value
function xmls.value(str, pos)
	if str:sub(pos, pos) == '"' then
		pos = str:match("^[^\"]*()", pos + 1)
		if str:sub(pos, pos) ~= '"' then
			error("Unclosed attribute value at " .. pos)
		end
	else
		pos = str:match("^[^']*()", pos + 1)
		if str:sub(pos, pos) ~= "'" then
			error("Unclosed attribute value at " .. pos)
		end
	end
	return str:match("^[ \t\r\n]*()", pos + 1), xmls.attr, pos - 1
end

-- End of tag
-- Use at ">" or "/>"
-- Transition to Text
-- Return true if opening tag, false if self-closing
function xmls.tagend(str, pos)
	-- todo: figure out when this could possibly be called if it isn't / or >
	-- xmls.attr will defer to this if it runs into the end of file
	local sigil = str:sub(pos, pos)
	if sigil == ">" then
		return pos + 1, xmls.text, true
	elseif sigil == "/" then
		pos = pos + 1
		if str:sub(pos, pos) == ">" then
			return pos + 1, xmls.text, false
		else
			error("Malformed tag end at " .. pos)
		end
	else
		error("Malformed tag end at " .. pos)
	end
end

-- Plain text
-- Use after >
-- Transition to Tag
-- Return end of content
function xmls.text(str, pos)
	pos = str:match("[^<]*()", pos)
	return pos, xmls.markup, pos - 1
end

-- End of file
-- Do not use
-- Throws an error, shouldn't have read any further
function xmls.eof(str, pos)
	error("Exceeding end of file")
end

---------------------------------------------

-- Get one attribute key-value pair, iterable
-- Use at Attr
-- Transition to Attr and return pos, key, value
-- Transition to TagEnd and return nil
function xmls.attrs(str, pos)
	local state, posB
	local posA = pos
	pos, state, posB = xmls.attr(str, pos)
	if state == xmls.value then
		local key = str:sub(posA, posB)
		posA = pos + 1 -- skip the quote
		pos, state, posB = xmls.value(str, pos)
		return pos, key, str:sub(posA, posB)
	else
		return nil
	end
end
--[[ Example:
local str = '<test key="value" key="value">'
local pos = 7
for i, k, v in xmls.attrs, str, pos do
	pos = i
	print(k, v)
end
print(xmls.tagend(str, pos))
]]

-- Skip attributes and content of a tag
-- Use at Attr
-- Transition to Text
function xmls.skip(str, pos)
	pos = xmls.skipAttrs(str, pos)
	return xmls.skipContent(str, pos)
end

-- Skip attributes of a tag
-- Use at Attr
-- Transition to TagEnd
function xmls.skipAttrs(str, pos)
	return str:match("^[^/>]*()", pos), xmls.tagend
end
--[[ Example:
local str = '<test key="value" key="value">'
local pos = 7
pos = xmls.wasteAttrs(str, pos)
print(xmls.tagend(str, pos))
]]

-- Skip the content of a tag.
-- Use at TagEnd
-- Transition to Text
function xmls.skipContent(str, pos)
	local pos, state, value = pos, xmls.tagend
	local level = 0
	repeat
		if state == xmls.attrs then
			-- optional, do not bother with parsing all attributes
			state = xmls.skipAttrs
			pos, state, value = state(str, pos)
		elseif state == xmls.tagend then
			-- increase level if tag is an opening tag
			pos, state, value = state(str, pos)
			if value == true then
				level = level + 1
			end
		elseif state == xmls.etag then
			-- decrease level if tag is a closing tag
			level = level - 1
			pos, state, value = state(str, pos)
		else
			-- skip everything else
			pos, state, value = state(str, pos)
		end
	until level == 0
	return pos, state
end

-- testing

if false then

local back = {}
for k,v in pairs(xmls) do back[v] = k end

-- local str = "<foo bar='123'></foo>"
local file = assert(io.open("equip.xml"))
local str = file:read("*a")
file:close()

local op = xmls.text
local pos = 1
local ret

print()
while true do
	local a, b = back[op], pos
	local ret
	pos, op, ret = op(str, pos)
	print(a, b, ret)
	if op == xmls.eof then return end
end

end

return xmls
