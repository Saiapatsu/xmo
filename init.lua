--[[
MIT License

Copyright (c) 2022 twiswist

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

local xmls = {}

-- States
-- ======

-- Map state to state name
xmls.names = {} -- [function] = string

-- Plain text
-- Use outside of markup
-- Transition to Markup
-- Return end of text
function xmls.text(str, pos)
	pos = str:match("[^<]*()", pos)
	return pos, xmls.markup, pos
end

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
	return posSpace, xmls.attr, posName
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
	return posSpace + 1, xmls.text, posName
end

-- Content of CDATA section
-- Use after "<![CDATA["
-- Transition to Text
-- Return end of content
function xmls.cdata(str, pos)
	local pos2 = str:match("%]%]>()", pos)
	if pos2 ~= nil then
		return pos2, xmls.text, pos2 - 3
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
		return pos2, xmls.text, pos2 - 3
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
		return pos2, xmls.text, pos2 - 2
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
		return posSpace, xmls.value, posName
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
	return posSpace, xmls.attr, posQuote
end

-- End of tag
-- Use at ">" or "/>"
-- Transition to Text
-- Return true if opening tag, false if self-closing
function xmls.tagend(str, pos)
	-- warning: xmls.attr will transition to this if it runs into the end of file
	-- c port?: return enum instead of bool
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

-- End of file
-- Do not use
-- Throws an error, shouldn't have read any further
function xmls.eof(str, pos)
	return xmls.error("Exceeding end of file", str, pos)
end

-- Populate xmls.names
for k,v in pairs(xmls) do
	xmls.names[v] = k
end

-- Supplementary methods
-- =====================

-- Skip attributes and content of a tag
-- Use at Attr
-- Transition to Text
function xmls.skipTag(str, pos)
	pos = xmls.skipAttr(str, pos)
	return xmls.skipContent(str, pos)
end

-- Skip attributes of a tag
-- Use between a < and a >
-- Transition to TagEnd
function xmls.skipAttr(str, pos)
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
			-- pos, state = state(str, pos) --> attr
			pos, state = xmls.skipAttr(str, pos) --> tagend
			pos, state, value = state(str, pos) --> text
			if value == true then
				level = level + 1
			end
			
		elseif state == xmls.etag then --> etag
			level = level - 1
			pos, state = state(str, pos) --> text
			
		else --> ?
			pos, state = state(str, pos) --> text
		end
	until level == 0
	return pos, state, posB
end

-- Error reporting supplements
-- ===========================

-- Get line number and position in line from string and position in string
function xmls.linepos(str, pos)
	local line = 0
	local lastpos = 1
	-- find first line break that's after pos
	for linestart in string.gmatch(str, "()[^\n]*") do
		if pos < linestart then break end
		lastpos = linestart
		line = line + 1
	end
	return line, pos - lastpos + 1
end

function xmls.traceback(str, pos, path)
	local line, linepos = xmls.linepos(str, pos)
	if path then
		return string.format("%s:%d:%d:%d", path, pos, line, linepos)
	else
		return string.format("%d:%d:%d", pos, line, linepos)
	end
end

function xmls.error(reason, str, filepos)
	local line, linepos = xmls.linepos(str, filepos)
	return error(debug.traceback(string.format("%s at %d:%d:%d", reason, filepos, line, linepos), 2), 2)
end

-- Parsing state object
-- ====================

local xmo = {}
xmo.__index = xmo
xmls.xmo = xmo

-- Constructor
-- You're free to use an instance to store arbitrary data.
-- In particular, xmo:traceback() acts differently if path is set.
function xmls.new(str, pos, state)
	return setmetatable({
		str = str,
		pos = pos or 1,
		state = state or xmls.text,
	}, xmo)
end

-- Advance to the next state
function xmo:__call()
	local value
	self.pos, self.state, value = self.state(self.str, self.pos)
	return self.state, value
end

-- Use a supplemental method
function xmo:doState(state)
	local value
	self.pos, self.state, value = state(self.str, self.pos)
	return self.state, value
end

-- Skipping irrelevant content
-- ===========================

-- Use at Attr
-- Transition to Text
function xmo:skipTag()
	assert(self.state == xmls.attr)
	return self:doState(xmls.skipTag)
end

-- Use at Attr
-- Transition to TagEnd
function xmo:skipAttr()
	assert(self.state == xmls.attr)
	return self:doState(xmls.skipAttr)
end

-- Use at TagEnd
-- Transition to Text
function xmo:skipContent()
	assert(self.state == xmls.tagend)
	return self:doState(xmls.skipContent)
end

-- Manual extraction
-- =================

-- Use at Attr
-- Transition to Value and return key
-- Transition to TagEnd and return nil
function xmo:getKey()
	local posA = self.pos
	local state, posB = self()
	if state == xmls.value then
		return self:cut(posA, posB)
	else
		return nil
	end
end

-- Use at Attr
-- Transition to Value and return keyPos, keyLast
-- Transition to TagEnd and return nil
function xmo:getKeyPos()
	local posA = self.pos
	local state, posB = self()
	if state == xmls.value then
		return posA, posB
	else
		return nil
	end
end

-- Use at Value
-- Transition to Attr and return value
function xmo:getValue()
	return self:cut(self.pos + 1, select(2, self()))
end

-- Use at Value
-- Transition to Attr and return valuePos, valueLast
function xmo:getValuePos()
	return self.pos + 1, select(2, self())
end

-- Use at TagEnd
-- Transition to Text
-- Return inner XML
function xmo:getInner()
	assert(self.state == xmls.tagend)
	local state, value = self() --> text
	if value == true then
		return self:cut(self.pos, select(2, self:doState(xmls.skipInner))) --> text
	else
		return ""
	end
end

-- Iterables
-- =========

-- Use at Text
-- Return tag name at Attr
-- Bring to Text
-- Transition to EOF
function xmo:forRoot()
	assert(self.state == xmls.text)
	return xmo.getRoot, self
end

-- Use at Attr
-- Return key, value at Attr
-- Transition to TagEnd
function xmo:forAttr()
	assert(self.state == xmls.attr)
	return xmo.getAttr, self
end

-- Use at Attr
-- Return keypos, keylastpos, valuepos, valuelastpos at Attr
-- Transition to TagEnd
function xmo:forAttrPos()
	assert(self.state == xmls.attr)
	return xmo.getAttrPos, self
end

-- Use at Attr
-- Return key at Attr
-- Transition to Value
function xmo:forKey()
	assert(self.state == xmls.attr)
	return xmo.getKey, self
end

-- Use at Attr
-- Return keyPos, keyLast at Attr
-- Transition to Value
function xmo:forKeyPos()
	assert(self.state == xmls.attr)
	return xmo.getKeyPos, self
end

-- Use at TagEnd
-- Return tag name, inner XML at Text
-- Transition to Text
function xmo:forSimple()
	assert(self.state == xmls.tagend)
	local state, value = self()
	return value and xmo.getSimple or xmo.getNothing, self
end

-- Use at TagEnd
-- Return state at ?
-- Bring to Text
-- Transition to Text
function xmo:forMarkup()
	assert(self.state == xmls.tagend)
	local state, value = self()
	return value and xmo.getMarkup or xmo.getNothing, self
end

-- Use at TagEnd
-- Return tag name at Attr
-- Bring to Text
-- Transition to Text
function xmo:forTag()
	assert(self.state == xmls.tagend)
	local state, value = self()
	return value and xmo.getTag or xmo.getNothing, self
end

-- Iterators
-- =========

-- Use at Text
-- Do nothing
function xmo.getNothing() end

-- Use at Text
-- Transition to Attr and return tag name
-- Transition to Text and return nil
function xmo:getRoot()
	self() --> markup
	while true do
		local state = self() --> ?
		if state == xmls.stag then
			return self:cut(self.pos, select(2, self())) --> attr
		elseif state == xmls.eof then
			return nil
		end
	end
end

-- Use at Attr
-- Transition to Attr and return key, value
-- Transition to TagEnd and return nil
function xmo:getAttr()
	local posA, posB, state, key
	posA = self.pos
	state, posB = self()
	if state == xmls.value then
		key = self:cut(posA, posB)
		posA = self.pos + 1 -- skip the quote
		state, posB = self()
		return key, self:cut(posA, posB)
	else
		return nil
	end
end

-- Use at Attr
-- Transition to Attr and return keypos, keylastpos, valuepos, valuelastpos
-- Transition to TagEnd and return nil
function xmo:getAttrPos()
	local posA, posB, posC, posD, state
	posA = self.pos
	state, posB = self()
	if state == xmls.value then
		posC = self.pos + 1 -- skip the quote
		state, posD = self()
		return posA, posB, posC, posD
	else
		return nil
	end
end

-- Use at Text
-- Transition to ? and return state
-- Transition to Text and return nil
function xmo:getMarkup()
	self() --> markup
	local state = self() --> ?
	if state ~= xmls.etag then
		return state
	else
		self() --> text
		return nil
	end
end

-- Use at Text
-- Transition to Attr and return tag name
-- Transition to Text and return nil
function xmo:getTag()
	self() --> markup
	while true do
		local state = self() --> ?
		if state == xmls.stag then
			return self:cut(self.pos, select(2, self())) --> attr
		elseif state == xmls.etag then
			self() --> text
			return nil
		end
	end
end

-- Use at Text
-- Transition to Text and return tag name, tag content
-- Transition to Text and return nil
function xmo:getSimple()
	self() --> markup
	while true do
		local state = self() --> ?
		if state == xmls.stag then
			local name = self:cut(self.pos, select(2, self())) --> attr
			self:doState(xmls.skipAttr) --> tagend
			local state, value = self() --> text
			if value == true then
				return name, self:cut(self.pos, select(2, self:doState(xmls.skipInner))) --> text
			else
				return name, ""
			end
		elseif state == xmls.etag then
			self() --> text
			return nil
		end
	end
end

-- Declarative parsing
-- ===================

-- Use at TagEnd
-- Transition to Text
function xmo:doTags(tree)
	assert(self.state == xmls.tagend)
	for name in self:forTag() do
		self:doSwitch(tree[name], name)
	end
end

-- Use at Start
-- Transition to EOF
function xmo:doRoots(tree)
	assert(self.state == xmls.text)
	for name in self:forRoot() do
		self:doSwitch(tree[name], name)
	end
end

-- Use at Attr
-- Transition to Text
function xmo:doSwitch(action, name)
	local case = type(action)
	
	if case == "nil" then
		return self:doState(xmls.skipTag)
		
	elseif case == "table" then
		self:doState(xmls.skipAttr)
		for name in self:forTag() do
			self:doSwitch(action[name], name)
		end
		
	elseif case == "function" then
		return action(self, name)
	end
end

-- Use at Attr
-- Return map of attributes
-- Transition to TagEnd
function xmo:getAttrMap(tbl)
	assert(self.state == xmls.attr)
	tbl = tbl or {}
	for k, v in xmo.getAttr, self do
		tbl[k] = v
	end
	return tbl
end

-- Other
-- =====

function xmo:cut(a, b)
	return self.str:sub(a, b - 1)
end

function xmo:cutEnd(a)
	return self.str:sub(a)
end

-- Return a string in the form of [path:]line:pos
function xmo:traceback(pos)
	return xmls.traceback(self.str, pos or self.pos, self.path)
end

-- End
-- ===

return xmls
