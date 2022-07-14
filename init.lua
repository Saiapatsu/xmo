--[[
-- xmls2
-- minimal XML parsing utilities in Lua

code todo:
	make parsing more bulletproof/more error-happy
	look over all errors and ensure the positions are right

spec todo:
	https://www.w3.org/TR/xml/
	add a variant of Text that goes up to entities, leaving it up to the user to expand them?
	implement entities in attribute values
	add XML preamble support, if only to skip it entirely
	parse names correctly per https://www.w3.org/TR/xml/#charsets

]]

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

local xmls = {}

-- Error reporting
-- ===============

function xmls.position(str, pos)
	local line, lastpos = 0
	local lastline = 1
	-- find first line break that's after pos
	for linestart in string.gmatch(str, "()[^\n]*") do
		if pos < linestart then break end
		lastpos = linestart
		line = line + 1
	end
	return pos .. " (" .. line .. ", " .. pos - lastpos + 1 .. ")"
end

function xmls.error(reason, str, pos)
	return error(debug.traceback(reason .. " at " .. xmls.position(str, pos), 2), 2)
end

-- States
-- ======

-- Markup
-- Use at "<" or EOF
-- Transition to STag, ETag, CDATA, Comment, PI, MalformedTag or EOF
-- Return nil
function xmls.markup(str, pos)
	-- jump over the <
	pos = pos + 1
	
	if str:match("^%w()", pos) ~= nil then -- <tag
		return pos, xmls.stag, nil
	end
	
	local byte = str:byte(pos)
	
	if byte == 47 then -- </
		pos = pos + 1
		if str:match("^%w()", pos) ~= nil then -- </tag
			return pos, xmls.etag, nil
		else -- </>
			return pos - 1, xmls.malformed, nil
		end
		
	elseif byte == 33 then -- <!
		pos = pos + 1
		if str:sub(pos, pos + 1) == "--" then -- <!--
			return pos + 2, xmls.comment, nil
		elseif str:sub(pos, pos + 6) == "[CDATA[" then -- <![CDATA[
			return pos + 7, xmls.cdata, nil
		else -- <!asdf
			return pos - 1, xmls.malformed, nil
		end
		
	elseif byte == 63 then -- <?
		return pos + 1, xmls.pi, nil
		
	elseif pos >= #str then -- end of file
		return pos - 1, xmls.eof, nil
		
	else -- <\
		return pos, xmls.malformed, nil
	end
end

-- Name of starting tag
-- Use at name character after "<"
-- Transition to Attr
-- Return end of name
function xmls.stag(str, pos)
	local posName, posSpace = str:match("^%w+()[ \t\r\n]*()", pos)
	if posName == nil then
		return xmls.error("Invalid tag name", str, pos)
	end
	return posSpace, xmls.attr, posName - 1
end

-- Name of ending tag
-- Use at name character after "</"
-- Transition to Text
-- Return end of name
function xmls.etag(str, pos)
	local posName, posSpace = str:match("^%w+()[ \t\r\n]*()", pos)
	if posName == nil then
		return xmls.error("Invalid etag name", str, pos)
	end
	if str:byte(posSpace) ~= 62 then
		return xmls.error("Malformed etag", str, pos)
	end
	return posSpace + 1, xmls.text, posName - 1
end

-- Content of CDATA section
-- Use after "<![CDATA["
-- Transition to Text
-- Return end of content
function xmls.cdata(str, pos)
	local pos2 = str:match("%]%]>()", pos)
	if pos2 ~= nil then
		return pos2, xmls.text, pos2 - 4
	else
		return xmls.error("Unterminated CDATA section", str, pos)
	end
end

-- Content of comment
-- Use after "<!--"
-- Transition to Text
-- Return end of content
function xmls.comment(str, pos)
	local pos2 = str:match("%-%->()", pos)
	if pos2 ~= nil then
		return pos2, xmls.text, pos2 - 4
	else
		-- unterminated
		return xmls.error("Unterminated comment", str, pos)
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
	if pos2 ~= nil then
		return pos2, xmls.text, pos2 - 3
	else
		-- unterminated
		return xmls.error("Unterminated processing instruction", str, pos)
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
	return xmls.error("Malformed tag", str, pos)
end

-- Attribute name or end of tag (end of attribute list).
-- Use at attribute name or ">" or "/>"
-- Transition to Value and return end of name
-- Transition to TagEnd and return nil
function xmls.attr(str, pos)
	if str:match("^[^/>]()", pos) ~= nil then
		local posName, posSpace = str:match("^%w+()[ \t\r\n]*=[ \t\r\n]*()", pos)
		if posName == nil then
			return xmls.error("Malformed attribute", str, pos)
		end
		return posSpace, xmls.value, posName - 1
	else
		return pos, xmls.tagend, nil
	end
end

-- Attribute value
-- Use at "'" or '"'
-- Transition to Attr
-- Return end of value
function xmls.value(str, pos)
	local posQuote, posSpace = str:byte(pos)
	if posQuote == 34 then -- "
		posQuote, posSpace = str:match('()"[ \t\r\n]*()', pos + 1)
	elseif posQuote == 39 then -- '
		posQuote, posSpace = str:match("()'[ \t\r\n]*()", pos + 1)
	else
		return xmls.error("Unquoted attribute value", str, pos)
	end
	if posQuote == nil then
		return xmls.error("Unterminated attribute value", str, pos)
	end
	return posSpace, xmls.attr, posQuote - 1
end

-- End of tag
-- Use at ">" or "/>"
-- Transition to Text
-- Return true if opening tag, false if self-closing
function xmls.tagend(str, pos)
	-- warning: xmls.attr will transition to this if it runs into the end of file
	local byte = str:byte(pos)
	if byte == 62 then -- >
		return pos + 1, xmls.text, true
	elseif byte == 47 then -- /
		if str:byte(pos + 1) == 62 then -- >
			return pos + 2, xmls.text, false
		end
	end
	return xmls.error("Malformed tag end", str, pos)
end

-- Plain text
-- Use outside of markup
-- Transition to Markup
-- Return end of text
function xmls.text(str, pos)
	pos = str:match("[^<]*()", pos)
	return pos, xmls.markup, pos - 1
end

-- End of file
-- Do not use
-- Throws an error, shouldn't have read any further
function xmls.eof(str, pos)
	return xmls.error("Exceeding end of file", str, pos)
end

-- Supplemental methods
-- ====================

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
	-- fails when there's a slash in an attribute value!
	-- local pos2 = str:match("^[^/>]*()", pos)
	-- local pos2 = str:match("^.-()/?>", pos)
	-- if pos2 == nil then
		-- xmls.error("Unterminated start tag", str, pos2)
	-- end
	pos = str:match("^[^>]*()", pos)
	if str:byte(pos - 1) == 47 then
		return pos - 1, xmls.tagend
	else
		return pos, xmls.tagend
	end
end
--[[ Example:
local str = '<test key="value" key="value">'
local pos = 7
pos = xmls.wasteAttrs(str, pos)
print(xmls.tagend(str, pos))
]]

-- Skip the content and end tag of a tag
-- Use at TagEnd
-- Transition to Text
-- Return value is not useful
function xmls.skipContent(str, pos)
	local pos, state, value = xmls.tagend(str, pos) --> text
	if value == true then
		return xmls.skipInner(str, pos) --> text
	else
		return pos, state, nil
	end
end

-- Skip the content and end tag of a tag
-- Use at Text after TagEnd
-- Transition to Text
-- Return end of content just before the end tag
function xmls.skipInner(str, pos)
	local level, state, value = 1, xmls.text
	local posB
	repeat --> text
		pos, state = state(str, pos) --> markup
		posB = pos
		pos, state = state(str, pos) --> ?
		if state == xmls.stag then --> stag
			pos, state = state(str, pos) --> attr
			pos, state = xmls.skipAttrs(str, pos) --> tagend
			pos, state, value = state(str, pos) --> text
			if value == true then
				level = level + 1
			end
			
		elseif state == xmls.etag then --> etag
			level = level - 1
			pos, state = state(str, pos) --> text
			
		else --> ?
			repeat
				pos, state = state(str, pos)
			until state == xmls.text --> text
		end
	until level == 0
	return pos, state, posB - 1
end

-- Go to and consume next STag or ETag
-- Use at Text
-- Transition to Attr and return pos, xmls.attr, name
-- Transition to Text and return pos, xmls.text, name
function xmls.tags(str, pos)
	local state = xmls.text
	while true do
		repeat
			pos, state = state(str, pos)
		until state == xmls.markup
		pos, state = state(str, pos)
		if state == xmls.stag or state == xmls.etag then
			local posA, posB = pos
			pos, state, posB = state(str, pos)
			return pos, state, str:sub(posA, posB)
		end
	end
end
--[[ Example:
local str = "<root><testA key='value'>foo<!--test--><testing></testing></testA><testB/></root>"
local pos, state, value = 7, xmls.text
while true do
	pos, state, value = xmls.tags(str, pos)
	if state ~= xmls.attr then break end
	print(value)
	for i, k, v in xmls.attrs, str, pos do
		pos = i
		print("", k, v)
	end
	pos = xmls.skipContent(str, pos)
end
]]

return xmls
