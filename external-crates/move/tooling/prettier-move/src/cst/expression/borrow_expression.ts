// Copyright (c) The Move Contributors
// SPDX-License-Identifier: Apache-2.0

import { Node } from '../..';
import { MoveOptions, printFn, treeFn } from '../../printer';
import { AstPath, Doc, doc } from 'prettier';
const {} = doc.builders;

/** The type of the node implemented in this file */
export const NODE_TYPE = 'borrow_expression';

export default function (path: AstPath<Node>): treeFn | null {
	if (path.node.type === NODE_TYPE) {
		return printBorrowExpression;
	}

	return null;
}

/**
 * Print `borrow_expression` node.
 */
function printBorrowExpression(path: AstPath<Node>, options: MoveOptions, print: printFn): Doc {
	const ref = path.node.child(1)!.text == 'mut' ? '&mut ' : '&';
	return [
		...ref,
		path.call(print, 'nonFormattingChildren', 0), // borrow type
	];
}
