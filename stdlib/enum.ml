(* 
 * Enum - Enumeration over abstract collection of elements.
 * Copyright (C) 2003 Nicolas Cannasse
 *               2008 David Teller (contributor)
 * 
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version,
 * with the special exception on linking described in file LICENSE.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *)

(** {6 Representation} *)
type 'a t = {
	mutable count : unit -> int;
	mutable next : unit -> 'a;
	mutable clone : unit -> 'a t;
	mutable fast : bool;
}

(* raised by 'next' functions, should NOT go outside the API *)
exception No_more_elements

let make ~next ~count ~clone =
	{
		count = count;
		next = next;
		clone = clone;
		fast = true;
	}

(** {6 Internal utilities}*)
let _dummy () = assert false

(* raised by 'count' functions, may go outside the API *)
exception Infinite_enum

let return_no_more_elements () = raise No_more_elements
let return_no_more_count    () = 0
let return_infinite_count   () = raise Infinite_enum

(* Inlined from ExtList to avoid circular dependencies. *)
type 'a _mut_list = {
	hd : 'a;
	mutable tl : 'a _mut_list;
}

(* need to cheat typesystem, but can't depend on Obj module *)
external obj_magic : 'a -> 'b = "%identity" 

let force t =
	let rec clone enum count =
		let enum = ref !enum
		and	count = ref !count in
		{
			count = (fun () -> !count);
			next = (fun () ->
				match !enum with
				| [] -> raise No_more_elements
				| h :: t -> decr count; enum := t; h);
			clone = (fun () ->
				let enum = ref !enum
				and count = ref !count in
				clone enum count);
			fast = true;
		}
	in
	let count = ref 0 in
	let _empty = obj_magic [] in
	let rec loop dst =
		let x = { hd = t.next(); tl = _empty } in
		incr count;
		dst.tl <- x;
		loop x
	in
	let enum = ref _empty  in 
	(try
		enum := { hd = t.next(); tl = _empty };
		incr count;
		loop !enum;
	with No_more_elements -> ());
	let tc = clone (obj_magic enum) count in
	t.clone <- tc.clone;
	t.next <- tc.next;
	t.count <- tc.count;
	t.fast <- true

(* Inlined from {!LazyList}.

   This lazy list permits cloning enumerations constructed with {!from}
   without having to actually force them.*)
module MicroLazyList = struct
  type 'a ll_t      = ('a node_t) Lazy.t
  and  'a node_t = 
    | Nil
    | Cons of 'a * 'a ll_t

  let nil = lazy Nil

  let enum l =
    let rec aux (l:'a ll_t) : 'a t= 
      let reference = ref l in
      let e = make 
	~next:(fun () -> match Lazy.force !reference with
		 | Cons(x,t) -> reference := t; x
		 | _         -> raise No_more_elements )
        ~count:_dummy
        ~clone:(fun () -> aux !reference)
      in e.count <- (fun () -> force e; e.count());
	e
    in aux l

  let from f =
    let rec aux () =
      lazy (
	let item = try  Some (f ())
                   with No_more_elements -> None
	in match item with
	  | Some x -> Cons (x, aux () ) 
	  | _      -> Nil
      )
    in
      aux ()


end

let rec empty () =
	{
		count = return_no_more_count;
		next  = return_no_more_elements;
		clone = (fun () -> empty());
		fast = true;
	}

let from f =
	let e = {
		next = f;
		count = _dummy;
		clone = _dummy;
		fast = false;
	} in
	e.count <- (fun () -> force e; e.count());
	e.clone <- (fun () -> 
		  let e' =  MicroLazyList.enum(MicroLazyList.from f) in
		    e.next <- e'.next;
		    e.clone<- e'.clone;
		    e.count<- e'.count;
		    e.fast <- false;		    e.fast <- false;
	            e.clone () );
	e


let from2 next clone =
	let e = {
		next = next;
		count = _dummy;
		clone = clone;
		fast = false;
	} in
	e.count <- (fun () -> force e; e.count());
	e

let init n f = (*Experimental fix for init*)
  if n < 0 then invalid_arg "Enum.init";
  let count = ref n in
  let f' () =
    match !count with
      | 0 -> raise No_more_elements
      | _ -> decr count;
	  f ( n - 1 - !count)
  in let e = from f' in
    e.fast  <- true;
    e.count <- (fun () -> !count);
    e


let get t =
	try
		Some (t.next())
	with
		No_more_elements -> None

let push t e =
	let rec make t =
		let fnext = t.next in
		let fcount = t.count in
		let fclone = t.clone in
		let next_called = ref false in
		t.next <- (fun () ->
			next_called := true;
			t.next <- fnext;
			t.count <- fcount;
			t.clone <- fclone;
			e);
		t.count <- (fun () ->
			let n = fcount() in
			if !next_called then n else n+1);
		t.clone <- (fun () ->
			let tc = fclone() in
			if not !next_called then make tc;
			tc);
	in
	make t

let peek t =
	match get t with
	| None -> None
	| Some x ->
		push t x;
		Some x

let junk t =
	try
		ignore(t.next())
	with
		No_more_elements -> ()

let is_empty t =
	if t.fast then
		t.count() = 0
	else
		peek t = None

let count t =
	t.count()

let fast_count t =
	t.fast

let clone t =
	t.clone()

let iter f t =
	let rec loop () =
		f (t.next());
		loop();
	in
	try
		loop();
	with
		No_more_elements -> ()

let iteri f t =
	let rec loop idx =
		f idx (t.next());
		loop (idx+1);
	in
	try
		loop 0;
	with
		No_more_elements -> ()

let iter2 f t u =
	let push_t = ref None in
	let rec loop () =
		push_t := None;
		let e = t.next() in
		push_t := Some e;
		f e (u.next());
		loop ()
	in
	try
		loop ()
	with
		No_more_elements ->
			match !push_t with
			| None -> ()
			| Some e ->
				push t e

let iter2i f t u =
	let push_t = ref None in
	let rec loop idx =
		push_t := None;
		let e = t.next() in
		push_t := Some e;
		f idx e (u.next());
		loop (idx + 1)
	in
	try
		loop 0
	with
		No_more_elements ->
			match !push_t with
			| None -> ()
			| Some e -> push t e

let fold f init t =
	let acc = ref init in
	let rec loop() =
		acc := f (t.next()) !acc;
		loop()
	in
	try
		loop()
	with
		No_more_elements -> !acc

let foldi f init t =
	let acc = ref init in
	let rec loop idx =
		acc := f idx (t.next()) !acc;
		loop (idx + 1)
	in
	try
		loop 0
	with
		No_more_elements -> !acc

let fold2 f init t u =
	let acc = ref init in
	let push_t = ref None in
	let rec loop() =
		push_t := None;
		let e = t.next() in
		push_t := Some e;
		acc := f e (u.next()) !acc;
		loop()
	in
	try
		loop()
	with
		No_more_elements ->
			match !push_t with
			| None -> !acc
			| Some e ->
				push t e;
				!acc

let fold2i f init t u =
	let acc = ref init in
	let push_t = ref None in
	let rec loop idx =
		push_t := None;
		let e = t.next() in
		push_t := Some e;
		acc := f idx e (u.next()) !acc;
		loop (idx + 1)
	in
	try
		loop 0
	with
		No_more_elements ->
			match !push_t with
			| None -> !acc
			| Some e ->
				push t e;
				!acc

let find f t =
	let rec loop () =
		let x = t.next() in
		if f x then x else loop()
	in
	try
		loop()
	with
		No_more_elements -> raise Not_found

let rec map f t =
	{
		count = t.count;
		next = (fun () -> f (t.next()));
		clone = (fun () -> map f (t.clone()));
		fast = t.fast;
	}

let rec mapi f t =
	let idx = ref (-1) in
	{
		count = t.count;
		next = (fun () -> incr idx; f !idx (t.next()));
		clone = (fun () -> mapi f (t.clone()));
		fast = t.fast;
	}

let rec filter f t =
	let rec next() =
		let x = t.next() in
		if f x then x else next()
	in
	from2 next (fun () -> filter f (t.clone()))

let rec filter_map f t =
    let rec next () =
        match f (t.next()) with
        | None -> next()
        | Some x -> x
    in
	from2 next (fun () -> filter_map f (t.clone()))

let rec append ta tb = 
	let t = {
		count = (fun () -> ta.count() + tb.count());
		next = _dummy;
		clone = (fun () -> append (ta.clone()) (tb.clone()));
		fast = ta.fast && tb.fast;
	} in
	t.next <- (fun () ->
		try
			ta.next()
		with
			No_more_elements ->
				(* add one indirection because tb can mute *)
				t.next <- (fun () -> tb.next());
				t.count <- (fun () -> tb.count());
				t.clone <- (fun () -> tb.clone());
				t.fast <- tb.fast;
				t.next()
	);
	t

let rec concat t =
	let concat_ref = ref _dummy in
	let rec concat_next() =
		let tn = t.next() in
		concat_ref := (fun () ->
			try
				tn.next()
			with
				No_more_elements ->
					concat_next());
		!concat_ref ()
	in
	concat_ref := concat_next;
	from2 (fun () -> !concat_ref ()) (fun () -> concat (t.clone()))


let singleton x =
  init 1 (fun _ -> x)

(* break recursive dependency loop *)
module Array = struct
  external get: 'a array -> int -> 'a = "%array_safe_get"
  external unsafe_get: 'a array -> int -> 'a = "%array_unsafe_get"
  external unsafe_set: 'a array -> int -> 'a -> unit = "%array_unsafe_set"
  external create: int -> 'a -> 'a array = "caml_make_vect"
    
  let init l ~f =
    if l = 0 then [||] else
      let res = create l (f 0) in
      for i = 1 to pred l do
	unsafe_set res i (f i)
      done;
      res
end

let switchn n f e =
  let queues = Array.init n ~f:(fun _ -> Queue.create ())   in
  let gen i () = (*Generate the next value for the i^th enum*)
    let my_queue  = Array.unsafe_get queues i in
      if Queue.is_empty my_queue then (*Need to fetch next*)
	let rec aux () =     (*Keep fetching until an appropriate
				     item has been found*)
	  let next_item = e.next()    in
	  let position  = f next_item in
	    if  i = position then next_item
	    else 
	      (
		Queue.push next_item (Array.get queues position);
		aux ()
	      )
	in aux ()
      else Queue.take my_queue
  in Array.init ~f:(fun i -> from (gen i)) n

let switch f e =
  let a = switchn 2 (fun x -> if f x then 0 else 1) e in
    (a.(0), a.(1))

let seq init f cond = 
  let acc = ref init in
  let aux () = if cond !acc then Ref.pre acc f
               else raise No_more_elements
  in from aux

let repeat ?times x = match times with
  | None -> 
      let rec aux =
	{
	  count = return_infinite_count;
	  next  = (fun () -> x);
	  clone = (fun () -> aux);
	  fast  = true;
	} in aux
  | Some n ->
      init n (fun _ -> x)

let cycle ?times x = 
  let enum   = 
  match times with 
    | None   -> from (fun () -> clone x)
    | Some n -> init n (fun _ -> clone x)
  in concat enum

let range ?until x =
  let cond =  match until with
    | None   -> ( fun _ -> true   )
    | Some n -> ( fun m -> m <= n )
  in seq x ( ( + ) 1 ) cond


let drop n e =
  for i = 1 to n do
    junk e
  done

let close e =
  e.next <- return_no_more_elements;
  e.count<- return_no_more_count;
  e.clone<- empty

let before_do t f =
  let rec make t =
    let fnext  = t.next  in
    let fclone = t.clone in
    let next_called = ref false in
      t.next  <- (fun () -> f(); 
		    next_called := true;
		    t.clone <- fclone;
		    t.next  <- fnext ;
		    fnext () );

      t.clone <- (fun () ->
		    let tc = fclone() in
		      if not !next_called then make tc;
		      tc);
  in
    make t

let drop_while p e =
  let rec aux () = 
    match peek e with
      | None            -> e
      | Some x when p x -> junk e; aux ()
      | _               -> e
  in 
    before_do e aux; e

let take_while f t =
  let rec next () =
    let x = t.next () in
      if f x then x
      else        raise No_more_elements
  in from next
    

let ( -- ) x y = range x ~until:y

let ( --- ) x y = if x > y then y -- x 
                  else          x -- y

let ( ~~ ) a b = map Char.chr (range (Char.code a) ~until:(Char.code b))


let from_while f =
  from(fun () -> match f () with
	 | None   -> raise No_more_elements
	 | Some x -> x )
      

let from_loop data next =
  let r = ref data in
    from(fun () -> let (a,b) = next !r in
	   r := b;
	   a)

let seq_hide data next =
  from_loop data (fun data -> match next data with
		    | None   -> raise No_more_elements
		    | Some x -> x )

let slazy f = 
  let constructor = lazy (f ()) in
    make ~next: (fun () -> (Lazy.force constructor).next ())
      ~count:   (fun () -> (Lazy.force constructor).count())
      ~clone:   (fun () -> (Lazy.force constructor).clone())

let lsing f =
  init 1 (fun _ -> f ())



let lcons f e = append (lsing f) e
let lapp  f e = append (slazy f) e

let ising     = singleton
let icons f e = append (ising f) e
let iapp      = append



module ExceptionLess = struct
  let find f e =
    try  Some (find f e)
    with Not_found -> None
end
