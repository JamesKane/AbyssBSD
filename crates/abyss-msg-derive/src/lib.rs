// SPDX-License-Identifier: BSD-2-Clause

//! `#[derive(Wire)]` for the AbyssBSD message primitive.
//!
//! Generates the [`Wire`] impl — the typed view over a `Value`
//! (`docs/design/wire-format.md` §7). A struct becomes a `dict`; an enum
//! becomes a `variant`.
//!
//! The generated code refers to the message primitive as `::abyss_msg`,
//! so the deriving crate must depend on `abyss-msg`.
//!
//! [`Wire`]: https://docs.rs/abyss-msg

use proc_macro::TokenStream;
use proc_macro2::TokenStream as TokenStream2;
use quote::{format_ident, quote};
use syn::{
    Attribute, Data, DataEnum, DataStruct, DeriveInput, Field, Fields, GenericArgument, Index,
    LitStr, PathArguments, Type, Variant, parse_macro_input, parse_quote,
};

/// Derive [`Wire`](https://docs.rs/abyss-msg) for a struct or enum.
#[proc_macro_derive(Wire, attributes(wire))]
pub fn derive_wire(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    expand(&input)
        .unwrap_or_else(syn::Error::into_compile_error)
        .into()
}

/// Derive [`Method`](https://docs.rs/abyss-msg) for an interface's message
/// enum — the per-variant method ordinal and kind (§2.9), and the
/// interface's rights classes from `#[rights(...)]` tags (§3.3).
#[proc_macro_derive(Method, attributes(request, command, event, rights))]
pub fn derive_method(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    expand_method(&input)
        .unwrap_or_else(syn::Error::into_compile_error)
        .into()
}

/// Derive the typed-request layer (§2.10) for an interface's message enum:
/// `From<payload>` for each variant, and `Request` for each `#[request]`
/// variant's payload type.
#[proc_macro_derive(Request, attributes(request, command, event, rights))]
pub fn derive_request(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    expand_request(&input)
        .unwrap_or_else(syn::Error::into_compile_error)
        .into()
}

fn expand(input: &DeriveInput) -> syn::Result<TokenStream2> {
    let rule = container_rename_rule(&input.attrs)?;
    let (to_body, from_body) = match &input.data {
        Data::Struct(data) => struct_body(data, &rule)?,
        Data::Enum(data) => enum_body(data, &rule)?,
        Data::Union(_) => {
            return Err(syn::Error::new_spanned(
                input,
                "Wire cannot be derived for a union",
            ));
        }
    };

    let name = &input.ident;
    let mut generics = input.generics.clone();
    for type_param in generics.type_params_mut() {
        type_param.bounds.push(parse_quote!(::abyss_msg::Wire));
    }
    let (impl_generics, ty_generics, where_clause) = generics.split_for_impl();

    Ok(quote! {
        #[automatically_derived]
        impl #impl_generics ::abyss_msg::Wire for #name #ty_generics #where_clause {
            fn to_wire(&self, __handles: &mut ::abyss_msg::HandleSink) -> ::abyss_msg::Value {
                #to_body
            }

            fn from_wire(
                __value: &::abyss_msg::Value,
                __handles: &mut ::abyss_msg::HandleStore,
            ) -> ::core::result::Result<Self, ::abyss_msg::WireError> {
                #from_body
            }
        }
    })
}

// --- Method: a message enum → its routing identity -------------------------

fn expand_method(input: &DeriveInput) -> syn::Result<TokenStream2> {
    let Data::Enum(data) = &input.data else {
        return Err(syn::Error::new_spanned(
            input,
            "Method can only be derived for an enum — a message type is an \
             enum of an interface's requests, commands, and events",
        ));
    };

    let mut method_arms = Vec::new();
    let mut kind_arms = Vec::new();
    // Rights classes, in first-encountered order: each name, and the
    // bitmask of the method ordinals tagged with it (§3.3).
    let mut classes: Vec<(String, u32)> = Vec::new();
    for (index, variant) in data.variants.iter().enumerate() {
        let ordinal = u16::try_from(index).map_err(|_| {
            syn::Error::new_spanned(variant, "an interface cannot have more than 65536 methods")
        })?;
        let pattern = variant_pattern(variant);
        let kind = variant_kind(variant)?;
        method_arms.push(quote! { #pattern => #ordinal, });
        kind_arms.push(quote! { #pattern => #kind, });

        if let Some(class) = variant_rights_class(variant)? {
            // The object-rights mask is a `u32`, so a classed method's
            // ordinal must fit one (§3.3).
            if index >= 32 {
                return Err(syn::Error::new_spanned(
                    variant,
                    "a method with a `#[rights(...)]` class must have ordinal < 32 — \
                     the object-rights mask is a u32 (broker-and-transport.md §3.3)",
                ));
            }
            let bit = 1u32 << index;
            let name = class.to_string();
            match classes.iter_mut().find(|(existing, _)| *existing == name) {
                Some((_, mask)) => *mask |= bit,
                None => classes.push((name, bit)),
            }
        }
    }
    let class_entries: Vec<TokenStream2> = classes
        .iter()
        .map(|(name, mask)| quote! { (#name, #mask) })
        .collect();

    let name = &input.ident;
    let (impl_generics, ty_generics, where_clause) = input.generics.split_for_impl();

    Ok(quote! {
        #[automatically_derived]
        impl #impl_generics ::abyss_msg::Method for #name #ty_generics #where_clause {
            const RIGHTS_CLASSES: &'static [(&'static str, u32)] = &[ #(#class_entries),* ];

            fn method_id(&self) -> u16 {
                match self { #(#method_arms)* }
            }

            fn kind(&self) -> ::abyss_msg::MessageKind {
                match self { #(#kind_arms)* }
            }
        }
    })
}

/// The rights class a variant is tagged with — `#[rights(name)]`, at most
/// one. `None` for an untagged variant (an event, or a method in no class).
fn variant_rights_class(variant: &Variant) -> syn::Result<Option<syn::Ident>> {
    let mut class: Option<syn::Ident> = None;
    for attr in &variant.attrs {
        if attr.path().is_ident("rights") {
            if class.is_some() {
                return Err(syn::Error::new_spanned(
                    attr,
                    "a message variant has at most one `#[rights(...)]` class",
                ));
            }
            class = Some(attr.parse_args()?);
        }
    }
    Ok(class)
}

/// A `Self::Variant` pattern matching the variant whatever its field shape.
fn variant_pattern(variant: &Variant) -> TokenStream2 {
    let vident = &variant.ident;
    match &variant.fields {
        Fields::Unit => quote!(Self::#vident),
        Fields::Unnamed(_) => quote!(Self::#vident(..)),
        Fields::Named(_) => quote!(Self::#vident { .. }),
    }
}

/// The `MessageKind` a variant is marked with — exactly one of
/// `#[request]`, `#[command]`, `#[event]`.
fn variant_kind(variant: &Variant) -> syn::Result<TokenStream2> {
    let mut kind: Option<TokenStream2> = None;
    for attr in &variant.attrs {
        let marked = if attr.path().is_ident("request") {
            Some(quote!(::abyss_msg::MessageKind::Request))
        } else if attr.path().is_ident("command") {
            Some(quote!(::abyss_msg::MessageKind::Command))
        } else if attr.path().is_ident("event") {
            Some(quote!(::abyss_msg::MessageKind::Event))
        } else {
            None
        };
        if let Some(marked) = marked {
            if kind.is_some() {
                return Err(syn::Error::new_spanned(
                    attr,
                    "a message variant has exactly one kind: \
                     `#[request]`, `#[command]`, or `#[event]`",
                ));
            }
            kind = Some(marked);
        }
    }
    kind.ok_or_else(|| {
        syn::Error::new_spanned(
            variant,
            "a message variant must be marked `#[request]`, `#[command]`, or `#[event]`",
        )
    })
}

// --- Request: the typed-request layer of a message enum --------------------

fn expand_request(input: &DeriveInput) -> syn::Result<TokenStream2> {
    let Data::Enum(data) = &input.data else {
        return Err(syn::Error::new_spanned(
            input,
            "Request can only be derived for an interface's message enum",
        ));
    };

    let name = &input.ident;
    let (impl_generics, ty_generics, where_clause) = input.generics.split_for_impl();

    let mut items = Vec::new();
    for variant in &data.variants {
        let vident = &variant.ident;
        let payload = request_payload(variant)?;

        // Every variant's payload converts into the message enum, so the
        // `Cap` surface can take a payload value (§2.10).
        items.push(quote! {
            #[automatically_derived]
            impl #impl_generics ::core::convert::From<#payload>
                for #name #ty_generics #where_clause
            {
                fn from(__payload: #payload) -> Self {
                    Self::#vident(__payload)
                }
            }
        });

        // A `#[request]` variant's payload is a `Request`, paired with the
        // reply type from `reply = ...`.
        if let Some(reply) = request_reply(variant)? {
            items.push(quote! {
                #[automatically_derived]
                impl ::abyss_msg::Request for #payload {
                    type Reply = #reply;
                }
            });
        }
    }
    Ok(quote! { #(#items)* })
}

/// The single tuple-field payload type of a message-enum variant — §2.10
/// requires every variant to be `Variant(Payload)`.
fn request_payload(variant: &Variant) -> syn::Result<&Type> {
    match &variant.fields {
        Fields::Unnamed(fields) if fields.unnamed.len() == 1 => Ok(&fields.unnamed[0].ty),
        _ => Err(syn::Error::new_spanned(
            variant,
            "a message-enum variant is a single-field tuple — `Variant(Payload)` (§2.10)",
        )),
    }
}

/// The reply type of a `#[request(reply = T)]` variant, or `None` when the
/// variant is not a `#[request]`.
fn request_reply(variant: &Variant) -> syn::Result<Option<Type>> {
    for attr in &variant.attrs {
        if !attr.path().is_ident("request") {
            continue;
        }
        let mut reply: Option<Type> = None;
        attr.parse_nested_meta(|meta| {
            if meta.path.is_ident("reply") {
                reply = Some(meta.value()?.parse::<Type>()?);
                Ok(())
            } else {
                Err(meta.error("expected `reply = <type>`"))
            }
        })?;
        return reply.map(Some).ok_or_else(|| {
            syn::Error::new_spanned(attr, "a `#[request]` needs `reply = <type>` (§2.10)")
        });
    }
    Ok(None)
}

// --- structs → dict --------------------------------------------------------

fn struct_body(data: &DataStruct, rule: &RenameRule) -> syn::Result<(TokenStream2, TokenStream2)> {
    let fields = named_fields(&data.fields)?;

    let mut to_pushes = Vec::new();
    let mut from_lets = Vec::new();
    let mut idents = Vec::new();
    for field in fields {
        let ident = field.ident.as_ref().expect("named field");
        let access = quote!(&self.#ident);
        let (to, from) = dict_field(field, rule, &access)?;
        to_pushes.push(to);
        from_lets.push(from);
        idents.push(ident);
    }

    let to_body = quote! {
        let mut __entries: ::std::vec::Vec<(::std::string::String, ::abyss_msg::Value)> =
            ::std::vec::Vec::new();
        #(#to_pushes)*
        ::abyss_msg::Value::Dict(__entries)
    };
    let from_body = quote! {
        let __dict = match __value {
            ::abyss_msg::Value::Dict(__d) => __d,
            __other => {
                return ::core::result::Result::Err(::abyss_msg::WireError::TypeMismatch {
                    expected: "dict",
                    found: ::abyss_msg::Value::kind_name(__other),
                });
            }
        };
        let __lookup = |__name: &str| {
            __dict.iter().find(|(__k, _)| __k == __name).map(|(_, __v)| __v)
        };
        #(#from_lets)*
        ::core::result::Result::Ok(Self { #(#idents),* })
    };
    Ok((to_body, from_body))
}

// --- enums → variant -------------------------------------------------------

fn enum_body(data: &DataEnum, rule: &RenameRule) -> syn::Result<(TokenStream2, TokenStream2)> {
    let mut to_arms = Vec::new();
    let mut from_arms = Vec::new();

    for variant in &data.variants {
        let vident = &variant.ident;
        let tag = variant_wire_name(variant, rule)?;
        let (to_arm, from_arm) = match &variant.fields {
            Fields::Unit => (
                quote! {
                    Self::#vident => ::abyss_msg::Value::Variant {
                        tag: #tag.to_owned(),
                        value: ::core::option::Option::None,
                    },
                },
                quote! {
                    #tag => ::core::result::Result::Ok(Self::#vident),
                },
            ),
            Fields::Unnamed(fields) if fields.unnamed.len() == 1 => {
                let ty = &fields.unnamed[0].ty;
                (
                    quote! {
                        Self::#vident(__0) => ::abyss_msg::Value::Variant {
                            tag: #tag.to_owned(),
                            value: ::core::option::Option::Some(::std::boxed::Box::new(
                                ::abyss_msg::Wire::to_wire(__0, __handles),
                            )),
                        },
                    },
                    quote! {
                        #tag => {
                            let __p = __payload
                                .ok_or(::abyss_msg::WireError::MissingField(#tag))?;
                            ::core::result::Result::Ok(Self::#vident(
                                <#ty as ::abyss_msg::Wire>::from_wire(__p, __handles)?,
                            ))
                        }
                    },
                )
            }
            Fields::Unnamed(fields) => {
                let count = fields.unnamed.len();
                let binds: Vec<_> = (0..count).map(|i| format_ident!("__{}", i)).collect();
                let tys: Vec<_> = fields.unnamed.iter().map(|f| &f.ty).collect();
                let indices: Vec<_> = (0..count).map(Index::from).collect();
                (
                    quote! {
                        Self::#vident( #(#binds),* ) => ::abyss_msg::Value::Variant {
                            tag: #tag.to_owned(),
                            value: ::core::option::Option::Some(::std::boxed::Box::new(
                                ::abyss_msg::Value::List(::std::vec![
                                    #(::abyss_msg::Wire::to_wire(#binds, __handles)),*
                                ]),
                            )),
                        },
                    },
                    quote! {
                        #tag => {
                            let __p = __payload
                                .ok_or(::abyss_msg::WireError::MissingField(#tag))?;
                            let __items = match __p {
                                ::abyss_msg::Value::List(__l) if __l.len() == #count => __l,
                                __other => {
                                    return ::core::result::Result::Err(
                                        ::abyss_msg::WireError::TypeMismatch {
                                            expected: "list",
                                            found: ::abyss_msg::Value::kind_name(__other),
                                        },
                                    );
                                }
                            };
                            ::core::result::Result::Ok(Self::#vident(
                                #(<#tys as ::abyss_msg::Wire>::from_wire(
                                    &__items[#indices], __handles,
                                )?),*
                            ))
                        }
                    },
                )
            }
            Fields::Named(fields) => {
                let mut to_pushes = Vec::new();
                let mut from_lets = Vec::new();
                let mut idents = Vec::new();
                for field in &fields.named {
                    let ident = field.ident.as_ref().expect("named field");
                    let access = quote!(#ident);
                    let (to, from) = dict_field(field, rule, &access)?;
                    to_pushes.push(to);
                    from_lets.push(from);
                    idents.push(ident);
                }
                (
                    quote! {
                        Self::#vident { #(#idents),* } => {
                            let mut __entries: ::std::vec::Vec<
                                (::std::string::String, ::abyss_msg::Value)
                            > = ::std::vec::Vec::new();
                            #(#to_pushes)*
                            ::abyss_msg::Value::Variant {
                                tag: #tag.to_owned(),
                                value: ::core::option::Option::Some(::std::boxed::Box::new(
                                    ::abyss_msg::Value::Dict(__entries),
                                )),
                            }
                        }
                    },
                    quote! {
                        #tag => {
                            let __p = __payload
                                .ok_or(::abyss_msg::WireError::MissingField(#tag))?;
                            let __dict = match __p {
                                ::abyss_msg::Value::Dict(__d) => __d,
                                __other => {
                                    return ::core::result::Result::Err(
                                        ::abyss_msg::WireError::TypeMismatch {
                                            expected: "dict",
                                            found: ::abyss_msg::Value::kind_name(__other),
                                        },
                                    );
                                }
                            };
                            let __lookup = |__name: &str| {
                                __dict.iter().find(|(__k, _)| __k == __name).map(|(_, __v)| __v)
                            };
                            #(#from_lets)*
                            ::core::result::Result::Ok(Self::#vident { #(#idents),* })
                        }
                    },
                )
            }
        };
        to_arms.push(to_arm);
        from_arms.push(from_arm);
    }

    let to_body = quote! {
        match self { #(#to_arms)* }
    };
    let from_body = quote! {
        let (__tag, __payload) = match __value {
            ::abyss_msg::Value::Variant { tag: __t, value: __v } => {
                (__t.as_str(), __v.as_deref())
            }
            __other => {
                return ::core::result::Result::Err(::abyss_msg::WireError::TypeMismatch {
                    expected: "variant",
                    found: ::abyss_msg::Value::kind_name(__other),
                });
            }
        };
        match __tag {
            #(#from_arms)*
            __unknown => ::core::result::Result::Err(
                ::abyss_msg::WireError::UnknownVariant(__unknown.to_owned()),
            ),
        }
    };
    Ok((to_body, from_body))
}

/// Codegen for one named field of a dict-shaped body. `access` is a
/// `&FieldTy` expression. Returns `(to-wire push, from-wire let)`.
fn dict_field(
    field: &Field,
    rule: &RenameRule,
    access: &TokenStream2,
) -> syn::Result<(TokenStream2, TokenStream2)> {
    let ident = field.ident.as_ref().expect("named field");
    let name = field_wire_name(field, rule)?;

    if let Some(inner) = option_inner(&field.ty) {
        let to = quote! {
            if let ::core::option::Option::Some(__v) = #access {
                __entries.push((#name.to_owned(), ::abyss_msg::Wire::to_wire(__v, __handles)));
            }
        };
        let from = quote! {
            let #ident = match __lookup(#name) {
                ::core::option::Option::Some(__v) => ::core::option::Option::Some(
                    <#inner as ::abyss_msg::Wire>::from_wire(__v, __handles)?,
                ),
                ::core::option::Option::None => ::core::option::Option::None,
            };
        };
        Ok((to, from))
    } else {
        let ty = &field.ty;
        let to = quote! {
            __entries.push((#name.to_owned(), ::abyss_msg::Wire::to_wire(#access, __handles)));
        };
        let from = quote! {
            let #ident = {
                let __v = __lookup(#name)
                    .ok_or(::abyss_msg::WireError::MissingField(#name))?;
                <#ty as ::abyss_msg::Wire>::from_wire(__v, __handles)?
            };
        };
        Ok((to, from))
    }
}

// --- attributes & helpers --------------------------------------------------

/// How field and variant names map to wire names.
enum RenameRule {
    None,
    Kebab,
    Snake,
}

impl RenameRule {
    fn apply(&self, ident: &str) -> String {
        match self {
            RenameRule::None => ident.to_owned(),
            RenameRule::Kebab => delimit(ident, '-'),
            RenameRule::Snake => delimit(ident, '_'),
        }
    }
}

/// Lower-case `ident`, treating CamelCase humps and existing `_` / `-` as
/// word breaks, joining words with `delim`.
fn delimit(ident: &str, delim: char) -> String {
    let mut out = String::new();
    for (i, ch) in ident.char_indices() {
        if ch == '_' || ch == '-' {
            if i != 0 && !out.ends_with(delim) {
                out.push(delim);
            }
        } else if ch.is_ascii_uppercase() {
            if i != 0 && !out.is_empty() && !out.ends_with(delim) {
                out.push(delim);
            }
            out.push(ch.to_ascii_lowercase());
        } else {
            out.push(ch);
        }
    }
    out
}

fn named_fields(
    fields: &Fields,
) -> syn::Result<&syn::punctuated::Punctuated<Field, syn::Token![,]>> {
    match fields {
        Fields::Named(named) => Ok(&named.named),
        Fields::Unnamed(_) | Fields::Unit => Err(syn::Error::new_spanned(
            fields,
            "Wire on a struct requires named fields",
        )),
    }
}

fn field_wire_name(field: &Field, rule: &RenameRule) -> syn::Result<String> {
    if let Some(explicit) = explicit_rename(&field.attrs)? {
        return Ok(explicit);
    }
    let ident = field.ident.as_ref().expect("named field").to_string();
    Ok(rule.apply(&ident))
}

fn variant_wire_name(variant: &Variant, rule: &RenameRule) -> syn::Result<String> {
    if let Some(explicit) = explicit_rename(&variant.attrs)? {
        return Ok(explicit);
    }
    Ok(rule.apply(&variant.ident.to_string()))
}

/// `#[wire(rename = "...")]` on a field or variant.
fn explicit_rename(attrs: &[Attribute]) -> syn::Result<Option<String>> {
    let mut found = None;
    for attr in attrs {
        if !attr.path().is_ident("wire") {
            continue;
        }
        attr.parse_nested_meta(|meta| {
            if meta.path.is_ident("rename") {
                let lit: LitStr = meta.value()?.parse()?;
                found = Some(lit.value());
                Ok(())
            } else {
                Err(meta.error("expected `rename = \"...\"` here"))
            }
        })?;
    }
    Ok(found)
}

/// `#[wire(rename_all = "...")]` on the struct or enum.
fn container_rename_rule(attrs: &[Attribute]) -> syn::Result<RenameRule> {
    let mut rule = RenameRule::None;
    for attr in attrs {
        if !attr.path().is_ident("wire") {
            continue;
        }
        attr.parse_nested_meta(|meta| {
            if meta.path.is_ident("rename_all") {
                let lit: LitStr = meta.value()?.parse()?;
                rule = match lit.value().as_str() {
                    "kebab-case" => RenameRule::Kebab,
                    "snake_case" => RenameRule::Snake,
                    other => {
                        return Err(meta.error(format!(
                            "unknown rename_all {other:?} \
                             (expected \"kebab-case\" or \"snake_case\")"
                        )));
                    }
                };
                Ok(())
            } else {
                Err(meta.error("expected `rename_all = \"...\"` here"))
            }
        })?;
    }
    Ok(rule)
}

/// If `ty` is `Option<T>`, the inner `T`.
fn option_inner(ty: &Type) -> Option<&Type> {
    let Type::Path(path) = ty else {
        return None;
    };
    if path.qself.is_some() {
        return None;
    }
    let segment = path.path.segments.last()?;
    if segment.ident != "Option" {
        return None;
    }
    let PathArguments::AngleBracketed(args) = &segment.arguments else {
        return None;
    };
    if args.args.len() != 1 {
        return None;
    }
    match args.args.first()? {
        GenericArgument::Type(inner) => Some(inner),
        _ => None,
    }
}
