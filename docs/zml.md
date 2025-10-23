# zml - zss markup language

**zml** is a document language made for zss. It has the following features:
- It's a simple format for quickly creating documents for testing zss
- Has the bare minimum amount of features to satisfy the above point
- It's an example of integrating a document language with zss
- Borrows syntax elements from CSS to make for an intuitive syntax

## Creating a document
A document is just a tree of nodes. zml has two types of nodes: **text nodes** and **element nodes**.

### Text nodes
Defining a text node is as simple as typing a quoted string:
```css
"Hello from zml"
```
The syntax for quoted strings is exactly the same as the CSS syntax for strings.

### Element nodes
An element node consists of three parts: a **list of features**, an **inline style block**, and a **block of child nodes**. Features change how the element is matched against CSS selectors. The inline style block contains CSS styles that apply directly to the element. The block of child nodes is self-explanatory.

Example:
```css
#main (display: block) {}
```
This example defines a single element node. This element has a single feature: it has an ID feature with the name "main". This element also has an inline style block; it contains a declaration of the CSS 'display' property. Finally, it ends in a block of child nodes, which in this case is empty.

#### Features
A "feature" is something that affects how an element interacts with CSS selectors. An element can have any number of features, separated by spaces. In zml, the features you can define on an element are as follows:

##### Type
A type feature (also sometimes known as a tag name) is any valid CSS identifier. Unlike other features, an element is limited to having only 0 or 1 type features.

Examples:
```css
html
my-weird-type-42
```

##### ID
An ID feature consists of a CSS hash token along with a valid CSS identifier. An ID uniquely identifies an element in the document. If more than one element has the same ID, then only the one that appears first in the document will have that ID.

Examples:
```css
#alice
#jane-doe
```

##### Class
A class feature adds an element to a class. It consists of a dot along with a valid CSS identifier, with no space in between.

Examples:
```css
.class1
.flex
```

##### Attribute
An attribute feature gives an attribute to an element. Optionally, an attribute feature may also include a value. An attribute feature without a value looks like `[name]`, where "name" is a CSS identifier. An attribute feature with a value looks like `[name="value"]`, where "name" is like before, and "value" is either a CSS identifier or CSS string.

Examples:
```css
[wrap]
[width = auto]
[charset = 'utf-8']
```

#### Empty elements
It is also possible to define an element that has no features at all. Such an element is called "empty", and can be defined using the "empty feature": an asterisk.

```css
* {} /* An empty element. */
```

The empty feature `*` cannot appear alongside any other features.

#### Inline style blocks
An element may have an inline style block. This contains CSS declarations that apply directly to said element (these are also known as "style attributes"). Inline style blocks are optional, and if it exists, it must contain at least one declaration. Inline style blocks must appear after the element's list of features.

Syntactically, an inline style block is a series of CSS declarations surrounded by round brackets `()`. Each CSS declaration is exactly the same as ordinary CSS: a property name, followed by a colon `:`, followed by the property's value, followed by a semicolon `;`. Optionally, the last declaration in the block can omit its trailing semicolon.

Examples:
```css
(display: inline)
(width: 1280px; height: 720px;)
```

Declarations within the inline style block are treated as style attributes, and therefore have a higher precedence within the CSS cascade.

#### Child nodes
Element nodes can have child nodes, which are themselves other element or text nodes. Child nodes appear within a curly bracket `{}` block after an element's features and inline style block. The block of child nodes must be present even if there are no child nodes.

Example:
```css
body {
  "Hello"
  span {
    "World"
  }
  div {}
}
```
This example shows an element (**body**) with three child nodes: a text node and two element nodes. The first child element node (**span**) itself has a child text node. The second child element node (**div**) has no children of its own.

## Directives
zml defines directives, which can be used to modify a node in some way. Directives must appear just before the node they are modifying. Syntactically, directives look like `@directive(arguments)`, where `arguments` depends on the directive being used.

### List of directives
Each item here gives a description of each directive and the correct syntax for its arguments. At this time, zml only defines a single directive.

#### @name
**Syntax**: a CSS identifier
**Description**: Give an internal name to a node. When accessing the document using a programming language, this internal name can be used as a reference to this node. It is an error for more than one node to have the same internal name. The internal name is *not* a feature, and therefore doesn't affect the CSS cascade.

Example document:
```css
body {
  @name(my-custom-name) "Please replace this text"
}
```

Example Zig pseudo-code:
```zig
const string = someRuntimeKnownString(...);
const document = createDocument(...);
const node = document.getNodeByName("my-custom-name");
node.setText(string);
```

This example shows using a text node's internal name to directly refer to it and perform operations on it (in this case, replacing its textual content).

## Grammar

The grammar of zml documents is presented here.
This grammar definition uses the value definition syntax described in CSS Values and Units Level 4.

```
<root>               = <node>
<node>               = <directive>* [ <element> | <text> ]
<directive>          = <at-keyword-token> '(' <any-value> ')'

<element>            = <features> <inline-style-block>? <children>
<text>               = <string-token>

<features>           = '*' | [ <type> | <id> | <class> | <attribute> ]+
<type>               = <ident-token>
<id>                 = <hash-token>
<class>              = '.' <ident-token>
<attribute>          = '[' <ident-token> [ '=' <attribute-value> ]? ']'
<attribute-value>    = <ident-token> | <string-token>

<inline-style-block> = '(' <declaration-list> ')'

<children>           = '{' <node>* '}'

<ident-token>        = <defined in CSS Syntax Level 3>
<string-token>       = <defined in CSS Syntax Level 3>
<hash-token>         = <defined in CSS Syntax Level 3>
<at-keyword-token>   = <defined in CSS Syntax Level 3>
<any-value>          = <defined in CSS Syntax Level 3>
<declaration-list>   = <defined in CSS Style Attributes>
```

Whitespace or comments are required between the components of `<features>`.
The `<hash-token>` component of `<id>` must be an "id" hash token.
No whitespace or comments are allowed between the components of `<class>`.
No whitespace or comments are allowed between the `<at-keyword-token>` and '(' of `<directive>`.
